#!/usr/bin/env python3
# vrclm-files: the small file service VRChat Link Maker puts on your VPS (next to MediaMTX).
# Python 3.8+, standard library only. install.sh copies it to /usr/local/lib/vrclm-files/ and runs it as the
# systemd unit vrclm-files (DynamicUser, its config as a credential, its files in /var/lib/vrclm-files).
#
# Public (no password; ids are 22 random base64url characters, there are no listings):
#   GET/HEAD /v/<id>/index.m3u8 and /v/<id>/segNNNNN.ts   an uploaded video as HLS (MPEG-TS segments)
#   GET/HEAD /s/<stream>/now.m3u8                         the stream's current item (only with "same_link": true)
#   GET/HEAD /healthz                                      "ok vrclm-files <version>"
# Signed (HMAC-SHA256 with the stream's FileKey, see sign()):
#   PUT    /api/v1/items/<id>/<file>     one file (a segment up to max_file_mb, the playlist up to max_playlist_kb),
#                                        written to a temp file, checked, then renamed into the item
#   POST   /api/v1/items/<id>/commit     every segment in index.m3u8 is there -> the item is finished
#   GET    /api/v1/items/<id>            the item's files and sizes (to resume an upload)
#   DELETE /api/v1/items/<id>
#   GET    /api/v1/status                disk used vs budget, free disk, oldest item, last cleanup, this stream's items
#   POST   /api/v1/streams/<stream>/now  {"item": "<id>"} (or "") -> what /s/<stream>/now.m3u8 serves
# Cleanup runs every cleanup_min minutes: a finished item goes keep_hours after its last view (and max_age_hours after
# it was finished in any case), an unfinished one after idle_upload_hours without an upload. When an upload needs room,
# finished items go, the uploading stream's own first, each viewed longest ago first (never one viewed or finished in
# the last protect_min minutes, nor a stream's same-link item); if there is still no room the upload gets 507.
# Every file counts as at least 64 KB against the budget (what it really takes on disk), and an id that was used once
# can't be used again for tombstone_days.

import argparse
import base64
import hashlib
import hmac
import http.client
import ipaddress
import json
import os
import re
import secrets
import shutil
import signal
import socket
import socketserver
import stat
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Small header limits: the stdlib allows 100 headers of 64 KB each, which lets a few idle connections hold a lot of RAM.
# (http.client reads both as module globals each time it parses headers.)
http.client._MAXLINE = 8192
http.client._MAXHEADERS = 32

VERSION = 1
SIG_PREFIX = 'VRCLM1'
ID_RE = re.compile(r'[A-Za-z0-9_-]{22}')
STREAM_RE = re.compile(r'[A-Za-z0-9_-]{22,64}')
KEY_RE = re.compile(r'[A-Za-z0-9_-]{43}')
NAME_RE = re.compile(r'index\.m3u8|seg[0-9]{5}\.ts')
SEG_RE = re.compile(r'seg[0-9]{5}\.ts')
HEX64_RE = re.compile(r'[0-9a-f]{64}')
DIGITS_RE = re.compile(r'[0-9]{1,15}')
BASE_RE = re.compile(r'http://[A-Za-z0-9.-]+(:[0-9]{1,5})?|http://\[[0-9A-Fa-f:.]+\](:[0-9]{1,5})?')
PUBLIC_RE = re.compile(r'/v/([A-Za-z0-9_-]{22})/(index\.m3u8|seg[0-9]{5}\.ts)')
NOW_RE = re.compile(r'/s/([A-Za-z0-9_-]{22,64})/now\.m3u8')
API_ITEM_RE = re.compile(r'/api/v1/items/([A-Za-z0-9_-]{22})')
API_FILE_RE = re.compile(r'/api/v1/items/([A-Za-z0-9_-]{22})/(index\.m3u8|seg[0-9]{5}\.ts)')
API_COMMIT_RE = re.compile(r'/api/v1/items/([A-Za-z0-9_-]{22})/commit')
API_NOW_RE = re.compile(r'/api/v1/streams/([A-Za-z0-9_-]{22,64})/now')
EMPTY_SHA = hashlib.sha256(b'').hexdigest()
META = '.meta.json'
MB = 1024 * 1024
MIN_COST = 65536                 # a file counts as at least this much (blocks and inodes are not free)
NOT_SIGNED = 'not signed, an unknown stream, or a bad signature'

DEFAULTS = {
    'port': 80, 'bind': '', 'budget_mb': 4096, 'keep_hours': 24, 'max_age_hours': 72, 'idle_upload_hours': 2,
    'protect_min': 15, 'cleanup_min': 10, 'min_free_mb': 512, 'min_free_inodes': 20000, 'max_file_mb': 64,
    'max_playlist_kb': 1024, 'max_files': 4000, 'max_total_files': 20000, 'max_items': 200, 'max_items_per_stream': 50,
    'tombstone_days': 7, 'max_conns': 64, 'max_conns_per_ip': 8, 'timeout': 30, 'header_sec': 15, 'skew_sec': 300,
    'same_link': False, 'public_base': '',
}
INT_LIMITS = {
    'port': (1, 65535), 'budget_mb': (1, 1 << 30), 'keep_hours': (1, 24 * 365), 'max_age_hours': (1, 24 * 365),
    'idle_upload_hours': (1, 24 * 30), 'protect_min': (0, 24 * 60), 'cleanup_min': (1, 24 * 60),
    'min_free_mb': (0, 1 << 30), 'min_free_inodes': (0, 1 << 30), 'max_file_mb': (1, 1024), 'max_playlist_kb': (1, 16384),
    'max_files': (1, 100000), 'max_total_files': (1, 1000000), 'max_items': (1, 100000),
    'max_items_per_stream': (1, 100000), 'tombstone_days': (0, 365), 'max_conns': (1, 100), 'max_conns_per_ip': (1, 100),
    'timeout': (1, 3600), 'header_sec': (1, 600), 'skew_sec': (10, 86400),
}


class ConfigError(Exception):
    pass


def b64url_decode(s):
    return base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))


def load_config(path):
    try:
        with open(path, 'rb') as f:
            raw = json.loads(f.read(1 << 20).decode('utf-8'))
    except (OSError, ValueError) as e:
        raise ConfigError('cannot read the config: %s' % e.__class__.__name__)
    if not isinstance(raw, dict):
        raise ConfigError('the config is not a JSON object')
    cfg = dict(DEFAULTS)
    for k, v in raw.items():
        if k == 'streams':
            continue
        if k not in DEFAULTS:
            raise ConfigError('unknown setting: %s' % k[:40])
        if k in INT_LIMITS:
            lo, hi = INT_LIMITS[k]
            if isinstance(v, bool) or not isinstance(v, int) or not lo <= v <= hi:
                raise ConfigError('%s must be a whole number from %d to %d' % (k, lo, hi))
        elif k == 'same_link':
            if not isinstance(v, bool):
                raise ConfigError('same_link must be true or false')
        elif not isinstance(v, str):
            raise ConfigError('%s must be text' % k)
        cfg[k] = v
    if cfg['bind'] and not re.fullmatch(r'[0-9A-Fa-f.:]{2,45}', cfg['bind']):
        raise ConfigError('bind must be an IP address (or empty for all)')
    if cfg['public_base'] and not BASE_RE.fullmatch(cfg['public_base']):
        raise ConfigError('public_base must look like http://<address>[:port] (no slash at the end)')
    streams = {}
    for e in raw.get('streams') or []:
        if not isinstance(e, dict):
            raise ConfigError('a stream is not a JSON object')
        sid, key = e.get('id'), e.get('key')
        if not isinstance(sid, str) or not STREAM_RE.fullmatch(sid):
            raise ConfigError('a stream id is not 22-64 base64url characters')
        if not isinstance(key, str) or not KEY_RE.fullmatch(key):
            raise ConfigError('a stream key is not 43 base64url characters')
        if sid in streams:
            raise ConfigError('two streams have the same id')
        streams[sid] = b64url_decode(key)
    if not streams:
        raise ConfigError('the config has no streams')
    if len(set(streams.values())) != len(streams):
        raise ConfigError('two streams have the same key')
    cfg['streams'] = streams
    return cfg


def sign(key, stream, method, path, ts, body_sha):
    """The signature of a request: hex HMAC-SHA256(key, "VRCLM1\\n" stream \\n method \\n path \\n time \\n sha256(body))."""
    msg = '\n'.join((SIG_PREFIX, stream, method, path, str(ts), body_sha)).encode('ascii')
    return hmac.new(key, msg, hashlib.sha256).hexdigest()


def safe_log_text(s, n=200):
    """Text for the journal: no control characters, ids and keys shortened (an id is the link to a video)."""
    s = re.sub(r'[^\x20-\x7e]', '?', str(s))[:n]
    return re.sub(r'[A-Za-z0-9_-]{20,}', lambda m: m.group(0)[:4] + '..', s)


def log(msg):
    sys.stderr.write(safe_log_text(msg, 400) + '\n')
    sys.stderr.flush()


class LogLimit(object):
    """At most `burst` lines a minute for what strangers can trigger (refused requests); the rest is counted."""

    def __init__(self, burst=30):
        self.burst, self.lock = burst, threading.Lock()
        self.start, self.count, self.dropped = time.monotonic(), 0, 0

    def __call__(self, msg):
        with self.lock:
            now = time.monotonic()
            if now - self.start >= 60:
                if self.dropped:
                    log('(%d more refused requests in the last minute were not logged)' % self.dropped)
                self.start, self.count, self.dropped = now, 0, 0
            if self.count >= self.burst:
                self.dropped += 1
                return
            self.count += 1
        log(msg)


log_refused = LogLimit()


def cost_of(size):
    return max(size, MIN_COST)


def check_playlist(text, finished):
    """-> the segment names of an HLS playlist that may only list this item's segNNNNN.ts; StoreError if not."""
    if not text.startswith('#EXTM3U'):
        raise StoreError(409, 'index.m3u8 does not start with #EXTM3U')
    segs, end = [], False
    for raw in text.splitlines():
        l = raw.strip()
        if not l:
            continue
        if l.startswith('#'):
            if 'URI' in l.upper():
                raise StoreError(409, 'index.m3u8 refers to other files (URI=)')
            if l == '#EXT-X-ENDLIST':
                end = True
            continue
        if not SEG_RE.fullmatch(l):
            raise StoreError(409, 'index.m3u8 lists a file that is not segNNNNN.ts')
        segs.append(l)
    if finished and not end:
        raise StoreError(409, 'index.m3u8 has no #EXT-X-ENDLIST')
    if finished and not segs:
        raise StoreError(409, 'index.m3u8 lists no segments')
    return segs


class Item(object):
    __slots__ = ('id', 'stream', 'created', 'updated', 'last_view', 'finished', 'files', 'cost', 'dirty', 'playlist')

    def __init__(self, iid, stream, now):
        self.id, self.stream = iid, stream
        self.created = self.updated = now
        self.last_view = 0
        self.finished = 0
        self.files = {}
        self.cost = 0
        self.dirty = True
        self.playlist = None

    def set_file(self, name, size):
        if name in self.files:
            self.cost -= cost_of(self.files[name])
        self.files[name] = size
        self.cost += cost_of(size)

    @property
    def size(self):
        return sum(self.files.values())

    def idle_since(self):
        # A finished item: since its last view (or since it was finished, if nobody watched it yet).
        return max(self.last_view, self.finished) if self.finished else self.updated

    def meta(self):
        return {'stream': self.stream, 'created': self.created, 'updated': self.updated,
                'last_view': self.last_view, 'finished': self.finished}


class StoreError(Exception):
    def __init__(self, code, text):
        Exception.__init__(self, text)
        self.code, self.text = code, text


def default_inodes(path):
    if not hasattr(os, 'statvfs'):
        return None
    return os.statvfs(path).f_favail


class Store(object):
    """The items on disk and in memory. Every change goes through self.lock; file data is written outside it."""

    def __init__(self, root, cfg, clock=time.time, disk_free=None, inodes_free=None):
        self.root = root
        self.items_dir = os.path.join(root, 'items')
        self.tmp_dir = os.path.join(root, 'tmp')
        self.cfg = cfg
        self.clock = clock
        self.disk_free = disk_free or (lambda: shutil.disk_usage(self.root).free)
        self.inodes_free = inodes_free or (lambda: default_inodes(self.root))
        self.lock = threading.RLock()
        self.items = {}
        self.reserved = 0            # bytes of uploads in progress (counted as cost)
        self.reserved_files = 0
        self.uploading = {}          # temp path -> (stream, item id) of uploads in progress
        self.now_map = {}            # stream -> item id (same link)
        self.now_times = {}          # stream -> time of the last accepted switch
        self.seen_sigs = {}          # stream -> {signature: expiry} (replayed DELETE / switch requests are refused)
        self.tombstones = {}         # item id -> until when it can't be used again
        self.last_cleanup = 0
        self.last_cleanup_info = {}
        self.budget = cfg['budget_mb'] * MB
        os.makedirs(self.items_dir, mode=0o700, exist_ok=True)
        os.makedirs(self.tmp_dir, mode=0o700, exist_ok=True)
        self._load()

    def now(self):
        return int(self.clock())

    # ---- loading and saving
    def _load(self):
        for name in os.listdir(self.tmp_dir):
            self._remove_path(os.path.join(self.tmp_dir, name))       # (uploads that never ended)
        for name in os.listdir(self.items_dir):
            path = os.path.join(self.items_dir, name)
            if not ID_RE.fullmatch(name) or not os.path.isdir(path) or os.path.islink(path):
                self._remove_path(path)
                continue
            try:
                with open(os.path.join(path, META), 'rb') as f:
                    m = json.loads(f.read(65536).decode('utf-8'))
                it = Item(name, m['stream'], int(m['created']))
                it.updated, it.last_view, it.finished = int(m['updated']), int(m['last_view']), int(m['finished'])
                if not isinstance(it.stream, str) or not STREAM_RE.fullmatch(it.stream):
                    raise ValueError('stream')
            except (OSError, ValueError, KeyError, TypeError):
                log('removing %s: no valid meta file' % name)
                self._remove_path(path)
                continue
            if it.stream not in self.cfg['streams']:
                log('removing %s: its stream is no longer on this server' % name)
                self._remove_path(path)
                continue
            for fn in os.listdir(path):
                fp = os.path.join(path, fn)
                if NAME_RE.fullmatch(fn) and os.path.isfile(fp) and not os.path.islink(fp):
                    it.set_file(fn, os.path.getsize(fp))
                elif fn != META:
                    self._remove_path(fp)
            it.dirty = False
            self.items[name] = it
        try:
            with open(os.path.join(self.root, 'now.json'), 'rb') as f:
                m = json.loads(f.read(65536).decode('utf-8'))
            times = m.get('times', {}) if 'map' in m else {}
            for sid, iid in (m['map'] if 'map' in m else m).items():
                if sid in self.cfg['streams'] and iid in self.items and self.items[iid].finished:
                    self.now_map[sid] = iid
            for sid, ts in times.items():
                if sid in self.cfg['streams'] and isinstance(ts, int):
                    self.now_times[sid] = ts
        except (OSError, ValueError, AttributeError, KeyError, TypeError):
            pass
        try:
            with open(os.path.join(self.root, 'tombstones.json'), 'rb') as f:
                m = json.loads(f.read(4 * MB).decode('utf-8'))
            self.tombstones = dict((k, int(v)) for k, v in m.items() if ID_RE.fullmatch(k))
        except (OSError, ValueError, AttributeError, TypeError):
            pass

    def _write_json(self, path, obj):
        tmp = '%s.%s.tmp' % (path, secrets.token_hex(4))
        with open(tmp, 'w') as f:
            json.dump(obj, f)
        os.replace(tmp, path)

    def _save_meta(self, it):
        self._write_json(os.path.join(self.items_dir, it.id, META), it.meta())
        it.dirty = False

    def _save_now(self):
        self._write_json(os.path.join(self.root, 'now.json'), {'map': self.now_map, 'times': self.now_times})

    def _save_tombstones(self):
        try:
            self._write_json(os.path.join(self.root, 'tombstones.json'), self.tombstones)
        except OSError:
            pass

    def _remove_path(self, path):
        try:
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path, ignore_errors=True)
            else:
                os.unlink(path)
        except OSError:
            pass

    def _drop(self, it, why, save_tombstones=True):
        self.items.pop(it.id, None)
        days = self.cfg['tombstone_days']
        if days:
            self.tombstones[it.id] = self.now() + days * 86400
            if len(self.tombstones) > 50000:
                for k, _ in sorted(self.tombstones.items(), key=lambda kv: kv[1])[:10000]:
                    del self.tombstones[k]
            if save_tombstones:
                self._save_tombstones()
        for sid, iid in list(self.now_map.items()):
            if iid == it.id:
                del self.now_map[sid]
                self._save_now()
        self._remove_path(os.path.join(self.items_dir, it.id))
        log('removed item %s (%s, %d MB)' % (it.id, why, it.size // MB))

    # ---- accounting
    def used(self):
        return sum(it.cost for it in self.items.values())

    def files_total(self):
        return sum(len(it.files) for it in self.items.values())

    def _disk_ok(self, need, files):
        """Is there room on the disk itself (bytes and inodes) for need more bytes in files more files?"""
        if self.disk_free() - self.reserved - need < self.cfg['min_free_mb'] * MB:
            return False
        ino = self.inodes_free()
        return ino is None or ino - self.reserved_files - files >= self.cfg['min_free_inodes']

    def _room_ok(self, need):
        return self.used() + self.reserved + need <= self.budget and self._disk_ok(need, 0)

    def _victims(self, sid, keep_id):
        """Finished items that may go for room: the stream's own first, then the others; each viewed longest ago first."""
        protect = self.now() - self.cfg['protect_min'] * 60
        now_items = set(self.now_map.values())
        cands = [it for it in self.items.values() if it.finished and it.id != keep_id
                 and it.id not in now_items and it.idle_since() <= protect]
        return sorted(cands, key=lambda it: (it.stream != sid, it.idle_since(), it.created))

    def _ensure_room(self, need, keep_id, sid):
        """Evicts finished items until need more bytes fit; False = still no room (nothing is evicted then)."""
        if need > self.budget:
            return False
        victims, freed, plan = self._victims(sid, keep_id), 0, []
        while not (self.used() - freed + self.reserved + need <= self.budget and
                   self.disk_free() + freed - self.reserved - need >= self.cfg['min_free_mb'] * MB):
            if not victims:
                return False
            v = victims.pop(0)
            plan.append(v)
            freed += v.cost
        for v in plan:
            self._drop(v, 'room needed', save_tombstones=False)
        if plan:
            self._save_tombstones()
        return True

    # ---- public reads
    def open_public(self, iid, name):
        """-> (open binary file, size, finished) for a public GET, or None."""
        with self.lock:
            it = self.items.get(iid)
            if not it or name not in it.files:
                return None
            it.last_view = self.now()
            it.dirty = True
            path = os.path.join(self.items_dir, iid, name)
            fd = None
            try:
                fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_BINARY', 0))
                st = os.fstat(fd)
                if not stat.S_ISREG(st.st_mode):
                    os.close(fd)
                    return None
                return os.fdopen(fd, 'rb'), st.st_size, bool(it.finished)
            except OSError:
                if fd is not None:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                return None

    def _read_playlist(self, iid):
        with open(os.path.join(self.items_dir, iid, 'index.m3u8'), 'rb') as f:
            return f.read(self.cfg['max_playlist_kb'] * 1024 + 1).decode('ascii')

    def now_playlist(self, sid, base):
        """The playlist of the stream's current item with absolute segment URLs, or None."""
        with self.lock:
            iid = self.now_map.get(sid)
            it = self.items.get(iid) if iid else None
            if not it or not it.finished:
                return None
            if it.playlist is None:
                try:
                    it.playlist = self._read_playlist(iid)
                except (OSError, ValueError):
                    return None
            it.last_view = self.now()
            it.dirty = True
            out = []
            for line in it.playlist.splitlines():
                s = line.strip()
                if s and not s.startswith('#'):
                    s = '%s/v/%s/%s' % (base, iid, s)
                out.append(s)
            return ('\n'.join(out) + '\n').encode('ascii')

    # ---- signed requests
    def _check_replay(self, sid, sig, ts):
        """(lock held) A DELETE / switch signature seen before -> StoreError 409; else it is remembered."""
        now = self.now()
        seen = self.seen_sigs.setdefault(sid, {})
        if len(seen) > 1000:
            for k in [k for k, exp in seen.items() if exp < now]:
                del seen[k]
        if sig in seen:
            raise StoreError(409, 'a replayed request')
        if len(seen) > 5000:
            raise StoreError(429, 'too many requests; try again in a few minutes')
        seen[sig] = ts + 2 * self.cfg['skew_sec'] + 1

    def _own_item(self, sid, iid):
        it = self.items.get(iid)
        if not it or it.stream != sid:
            raise StoreError(404, 'no such item')
        return it

    def begin_put(self, sid, iid, name, length):
        """Checks one upload before its data comes, and reserves disk room for it -> the temp path to write it to.
        (Nothing is evicted and no item is made yet: that waits until the data is really there, in end_put.)"""
        if length <= 0:
            raise StoreError(400, 'an empty file')
        if name == 'index.m3u8' and length > self.cfg['max_playlist_kb'] * 1024:
            raise StoreError(413, 'index.m3u8 is larger than %d KB' % self.cfg['max_playlist_kb'])
        with self.lock:
            if self.tombstones.get(iid, 0) > self.now():
                raise StoreError(410, 'that item id was used before: upload under a new id')
            it = self.items.get(iid)
            if it and it.stream != sid:
                raise StoreError(410, 'that item id was used before: upload under a new id')
            if it and it.finished:
                raise StoreError(409, 'the item is finished (committed); upload it under a new id')
            if not it and sum(1 for x in self.items.values() if x.stream == sid) >= self.cfg['max_items_per_stream']:
                raise StoreError(507, 'this stream has too many items on the server')
            new_file = not it or name not in it.files
            if new_file and it and len(it.files) >= self.cfg['max_files']:
                raise StoreError(413, 'too many files in the item')
            if new_file and self.files_total() + self.reserved_files >= self.cfg['max_total_files']:
                raise StoreError(507, 'too many files on the server')
            if cost_of(length) > self.budget or not self._disk_ok(cost_of(length), 1):
                raise StoreError(507, 'the server is full')
            self.reserved += cost_of(length)
            self.reserved_files += 1
            tmp = os.path.join(self.tmp_dir, 'up-%s' % secrets.token_hex(8))
            self.uploading[tmp] = (sid, iid)
            return tmp

    def end_put(self, sid, iid, name, tmp, length, ok):
        """The upload ended (ok = all data there and its sha256 right): checks it, makes room and moves it in."""
        with self.lock:
            self.reserved -= cost_of(length)
            self.reserved_files -= 1
            self.uploading.pop(tmp, None)
            try:
                if not ok:
                    return
                it = self.items.get(iid)
                if (it and (it.stream != sid or it.finished)) or self.tombstones.get(iid, 0) > self.now():
                    raise StoreError(409, 'the item was removed or finished during the upload')
                text = None
                if name == 'index.m3u8':
                    try:
                        with open(tmp, 'rb') as f:
                            text = f.read(self.cfg['max_playlist_kb'] * 1024 + 1).decode('ascii')
                    except ValueError:
                        raise StoreError(409, 'index.m3u8 is not a plain ASCII playlist')
                    check_playlist(text, False)
                old = cost_of(it.files[name]) if it and name in it.files else 0
                if not self._ensure_room(cost_of(length) - old, iid, sid):
                    raise StoreError(507, 'the server is full')
                if not it:
                    if len(self.items) >= self.cfg['max_items']:
                        victims = self._victims(sid, None)
                        if not victims:
                            raise StoreError(507, 'too many items on the server')
                        self._drop(victims[0], 'too many items')
                    it = Item(iid, sid, self.now())
                    os.makedirs(os.path.join(self.items_dir, iid), mode=0o700, exist_ok=True)
                    self.items[iid] = it
                os.replace(tmp, os.path.join(self.items_dir, iid, name))
                tmp = None
                it.set_file(name, length)
                it.updated = self.now()
                it.playlist = None
                self._save_meta(it)
            finally:
                if tmp:
                    self._remove_path(tmp)

    def commit(self, sid, iid):
        with self.lock:
            it = self._own_item(sid, iid)
            if it.finished:
                return {'ok': True, 'finished': True, 'segments': None}
            if 'index.m3u8' not in it.files:
                raise StoreError(409, 'index.m3u8 is missing')
            try:
                text = self._read_playlist(iid)
            except (OSError, ValueError):
                raise StoreError(409, 'index.m3u8 is not a plain ASCII playlist')
            segs = check_playlist(text, True)
            missing = [s for s in segs if s not in it.files]
            if missing:
                raise StoreError(409, 'missing segments: %d (first: %s)' % (len(missing), missing[0]))
            it.finished = self.now()
            it.playlist = text
            self._save_meta(it)
            return {'ok': True, 'finished': True, 'segments': len(segs)}

    def listing(self, sid, iid):
        with self.lock:
            it = self._own_item(sid, iid)
            return {'id': it.id, 'finished': bool(it.finished), 'bytes': it.size,
                    'files': dict(sorted(it.files.items()))}

    def delete(self, sid, iid, sig, ts):
        with self.lock:
            it = self._own_item(sid, iid)
            self._check_replay(sid, sig, ts)
            self._drop(it, 'deleted by its stream')
            return {'ok': True}

    def set_now(self, sid, iid, sig, ts):
        with self.lock:
            if ts < self.now_times.get(sid, 0):
                raise StoreError(409, 'an older switch request')
            if iid:
                it = self._own_item(sid, iid)
                if not it.finished:
                    raise StoreError(409, 'the item is not finished')
            self._check_replay(sid, sig, ts)
            if iid:
                self.now_map[sid] = iid
            else:
                self.now_map.pop(sid, None)
            self.now_times[sid] = ts
            self._save_now()
            return {'ok': True, 'item': iid or None}

    def status(self, sid):
        with self.lock:
            now = self.now()
            fin = [it for it in self.items.values() if it.finished]
            own = sorted((it for it in self.items.values() if it.stream == sid), key=lambda it: it.created)
            free = ino = None
            try:
                free = self.disk_free()
                ino = self.inodes_free()
            except OSError:
                pass
            return {
                'version': VERSION, 'time': now, 'budget_bytes': self.budget, 'used_bytes': self.used(),
                'reserved_bytes': self.reserved, 'free_disk_bytes': free, 'min_free_bytes': self.cfg['min_free_mb'] * MB,
                'free_inodes': ino, 'files_total': self.files_total(), 'max_total_files': self.cfg['max_total_files'],
                'keep_hours': self.cfg['keep_hours'], 'items_total': len(self.items),
                'oldest_idle_sec': max([now - it.idle_since() for it in fin] or [0]),
                'oldest_age_sec': max([now - it.created for it in self.items.values()] or [0]),
                'cleanup': {'last_at': self.last_cleanup, 'age_sec': (now - self.last_cleanup) if self.last_cleanup else None,
                            'interval_sec': self.cfg['cleanup_min'] * 60, 'last': self.last_cleanup_info},
                'same_link': bool(self.cfg['same_link']), 'now_item': self.now_map.get(sid),
                'items': [{'id': it.id, 'finished': bool(it.finished), 'bytes': it.size, 'files': len(it.files),
                           'idle_sec': now - it.idle_since()} for it in own],
            }

    # ---- cleanup
    def cleanup(self):
        with self.lock:
            now = self.now()
            removed, freed = 0, 0
            keep = self.cfg['keep_hours'] * 3600
            max_age = self.cfg['max_age_hours'] * 3600
            idle = self.cfg['idle_upload_hours'] * 3600
            busy = set(v[1] for v in self.uploading.values())
            for it in list(self.items.values()):
                if it.stream not in self.cfg['streams']:
                    why = 'its stream is no longer on this server'
                elif it.finished and now - it.idle_since() > keep:
                    why = 'not viewed for %d h' % (keep // 3600)
                elif it.finished and now - it.finished > max_age:
                    why = 'older than %d h' % (max_age // 3600)
                elif not it.finished and now - it.updated > idle and it.id not in busy:
                    why = 'unfinished upload idle for %d h' % (idle // 3600)
                else:
                    continue
                removed += 1
                freed += it.size
                self._drop(it, why, save_tombstones=False)
            if self.used() + self.reserved > self.budget:     # (e.g. the budget was lowered)
                before = len(self.items)
                self._ensure_room(0, None, None)
                removed += before - len(self.items)
            try:
                for fn in os.listdir(self.tmp_dir):           # (temp files no upload owns)
                    p = os.path.join(self.tmp_dir, fn)
                    if p not in self.uploading:
                        self._remove_path(p)
            except OSError:
                pass
            for it in self.items.values():
                if it.dirty:
                    try:
                        self._save_meta(it)
                    except OSError:
                        pass
            for seen in self.seen_sigs.values():
                for k in [k for k, exp in seen.items() if exp < now]:
                    del seen[k]
            for k in [k for k, exp in self.tombstones.items() if exp < now]:
                del self.tombstones[k]
            self._save_tombstones()
            self.last_cleanup = now
            self.last_cleanup_info = {'removed': removed, 'freed_bytes': freed}
            free = -1
            try:
                free = self.disk_free() // MB
            except OSError:
                pass
            log('cleanup: removed %d item(s), freed %d MB; %d item(s), %d files, %d of %d MB used, %d MB free on disk' % (
                removed, freed // MB, len(self.items), self.files_total(), self.used() // MB, self.budget // MB, free))
            return self.last_cleanup_info


def client_key(ip):
    """What the per-client connection cap counts: an IPv4 address, or an IPv6 /64 (one host can have all of it)."""
    ip = ip.split('%', 1)[0]
    if ip.startswith('::ffff:') and '.' in ip:
        return ip[7:]
    if ':' in ip:
        try:
            return str(ipaddress.ip_network(ip + '/64', strict=False).network_address) + '/64'
        except ValueError:
            return ip
    return ip


class Server(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False
    allow_reuse_address = True
    request_queue_size = 64

    def __init__(self, addr, handler, store, cfg, family=socket.AF_INET):
        self.address_family = family
        self.store, self.cfg = store, cfg
        self.conn_lock = threading.Lock()
        self.conns = 0
        self.per_ip = {}
        self.deadlines = {}          # socket -> monotonic time by which its request line + headers must be in
        self.reaper_stop = threading.Event()
        ThreadingHTTPServer.__init__(self, addr, handler, bind_and_activate=False)
        try:
            if family == socket.AF_INET6:
                try:
                    self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                except (OSError, AttributeError):
                    pass
            self.server_bind()
            self.server_activate()
        except Exception:
            self.server_close()
            raise
        threading.Thread(target=self._reaper, daemon=True).start()

    def server_bind(self):
        # (HTTPServer.server_bind would look the address up in DNS: not needed here.)
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = 'vrclm-files', self.server_address[1]

    def server_close(self):
        self.reaper_stop.set()
        ThreadingHTTPServer.server_close(self)

    def set_deadline(self, sock, sec):
        with self.conn_lock:
            if sec is None:
                self.deadlines.pop(sock, None)
            else:
                self.deadlines[sock] = time.monotonic() + sec

    def _reaper(self):
        # A client that is slow to send its request (or idles on a keep-alive connection) is cut off: the per-read
        # timeout alone would let a byte every 29 s hold a connection for ever.
        while not self.reaper_stop.wait(0.5):
            now = time.monotonic()
            with self.conn_lock:
                late = [s for s, d in self.deadlines.items() if d < now]
                for s in late:
                    del self.deadlines[s]
            for s in late:
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def process_request(self, request, client_address):
        ip = client_key(client_address[0])
        with self.conn_lock:
            if self.conns >= self.cfg['max_conns'] or self.per_ip.get(ip, 0) >= self.cfg['max_conns_per_ip']:
                busy = True
            else:
                busy = False
                self.conns += 1
                self.per_ip[ip] = self.per_ip.get(ip, 0) + 1
        if busy:
            try:
                request.settimeout(1)
                request.sendall(b'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            ThreadingHTTPServer.process_request(self, request, client_address)
        except Exception:
            self._release(ip)
            raise

    def process_request_thread(self, request, client_address):
        try:
            ThreadingHTTPServer.process_request_thread(self, request, client_address)
        finally:
            self.set_deadline(request, None)
            self._release(client_key(client_address[0]))

    def _release(self, ip):
        with self.conn_lock:
            self.conns -= 1
            n = self.per_ip.get(ip, 1) - 1
            if n <= 0:
                self.per_ip.pop(ip, None)
            else:
                self.per_ip[ip] = n

    def handle_error(self, request, client_address):
        e = sys.exc_info()[1]
        if not isinstance(e, OSError):
            log('error: %s: %s' % (e.__class__.__name__, e))


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'vrclm-files/%d' % VERSION
    sys_version = ''
    timeout = 30

    # ---- plumbing
    def handle_one_request(self):
        # As BaseHTTPRequestHandler's, but with an 8 KB request line, and the request line + headers (or a keep-alive
        # wait) must arrive within header_sec.
        # (A short per-read timeout ends an idle wait; the reaper ends a slow trickle, as the next read finds the
        # socket shut down.)
        srv = self.server
        srv.set_deadline(self.connection, srv.cfg['header_sec'])
        self.connection.settimeout(srv.cfg['header_sec'])
        try:
            self.raw_requestline = self.rfile.readline(8193)
            if len(self.raw_requestline) > 8192:
                self.requestline = self.request_version = self.command = ''
                self.send_error(414)
                self.close_connection = True
                return
            if not self.raw_requestline:
                self.close_connection = True
                return
            ok = self.parse_request()
            srv.set_deadline(self.connection, None)
            self.connection.settimeout(self.timeout)
            if not ok:
                self.close_connection = True
                return
            method = getattr(self, 'do_' + self.command, None)
            if method is None:
                self.send_error(501, 'Unsupported method')
                return
            method()
            self.wfile.flush()
        except OSError:
            self.close_connection = True
        finally:
            srv.set_deadline(self.connection, None)

    def log_message(self, fmt, *args):
        pass

    def log_error(self, fmt, *args):
        try:
            log_refused('http: ' + (fmt % args))
        except Exception:
            pass

    def handle_expect_100(self):
        return True          # (answered later, after the signature and the room are checked)

    def reply(self, code, body=b'', ctype='text/plain; charset=utf-8', headers=None, close=False):
        if isinstance(body, str):
            body = body.encode('utf-8')
        elif isinstance(body, (dict, list)):
            body = (json.dumps(body) + '\n').encode('utf-8')
            ctype = 'application/json'
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Content-Type-Options', 'nosniff')
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        if close:
            self.send_header('Connection', 'close')
            self.close_connection = True
        self.end_headers()
        if self.command != 'HEAD' and body:
            self.wfile.write(body)

    def fail(self, code, text, close=False, headers=None):
        if self.path.startswith('/api/'):
            log_refused('%s %s -> %d %s' % (self.command, self.path, code, text))
            self.reply(code, {'ok': False, 'error': text}, close=close, headers=headers)
        else:
            self.reply(code, text + '\n', close=close, headers=headers)

    def split_path(self):
        """-> the path without a query, or None when it is not a plain origin-form path."""
        p = self.path
        if not p.startswith('/') or '%' in p or '\\' in p or '#' in p or '\x00' in p:
            return None
        return p.split('?', 1)[0]

    def content_length(self):
        """-> the Content-Length (0 when absent), or None for chunked / several / malformed values."""
        if self.headers.get('Transfer-Encoding') is not None:
            return None
        vals = self.headers.get_all('Content-Length') or []
        if not vals:
            return 0
        if len(vals) != 1 or not DIGITS_RE.fullmatch(vals[0].strip()):
            return None
        return int(vals[0].strip())

    def send_continue(self):
        if self.headers.get('Expect', '').lower() == '100-continue':
            self.send_response_only(100)
            self.end_headers()

    # ---- public
    def do_GET(self):
        self.route()

    def do_HEAD(self):
        self.route()

    def do_PUT(self):
        self.route()

    def do_POST(self):
        self.route()

    def do_DELETE(self):
        self.route()

    def route(self):
        try:
            p = self.split_path()
            if p is None or not self.request_version.startswith('HTTP/1.'):
                return self.fail(400, 'bad path', close=True)
            if p.startswith('/api/'):
                if '?' in self.path:
                    return self.fail(400, 'no query strings on the API', close=True)
                return self.api(p)
            if self.command not in ('GET', 'HEAD'):
                return self.fail(405, 'method not allowed', close=True, headers={'Allow': 'GET, HEAD'})
            if self.content_length() != 0:
                return self.fail(400, 'a GET has no body', close=True)
            if p == '/healthz':
                return self.reply(200, 'ok vrclm-files %d\n' % VERSION, headers={'Cache-Control': 'no-store'})
            m = PUBLIC_RE.fullmatch(p)
            if m:
                return self.serve_file(m.group(1), m.group(2))
            m = NOW_RE.fullmatch(p)
            if m and self.server.cfg['same_link'] and m.group(1) in self.server.cfg['streams']:
                body = self.server.store.now_playlist(m.group(1), self.server.cfg['public_base'])
                if body is not None:
                    return self.reply(200, body, 'application/vnd.apple.mpegurl',
                                      {'Cache-Control': 'no-cache, no-store, must-revalidate'})
            return self.fail(404, 'not found')
        except OSError:
            self.close_connection = True
        except Exception as e:
            log('error in %s %s: %s: %s' % (self.command, self.path, e.__class__.__name__, e))
            try:
                self.fail(500, 'internal error', close=True)
            except Exception:
                self.close_connection = True

    def serve_file(self, iid, name):
        got = self.server.store.open_public(iid, name)
        if not got:
            return self.fail(404, 'not found')
        f, size, finished = got
        with f:
            if name == 'index.m3u8':
                ctype = 'application/vnd.apple.mpegurl'
                cache = 'public, max-age=60' if finished else 'no-cache'
            else:
                ctype = 'video/mp2t'
                cache = 'public, max-age=86400, immutable'
            self.send_response(200)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(size))
            self.send_header('Cache-Control', cache)
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            if self.command == 'HEAD' or size == 0:
                return
            sent = self.connection.sendfile(f, 0, size)
            if sent != size:
                self.close_connection = True

    # ---- signed
    def verify(self, path, body_sha):
        """-> (stream id, time, signature) of a correctly signed request; raises StoreError(401) otherwise."""
        cfg = self.server.cfg
        sid = self.headers.get('X-Vrclm-Stream', '')
        ts = self.headers.get('X-Vrclm-Time', '')
        sig = self.headers.get('X-Vrclm-Sig', '').lower()
        key = cfg['streams'].get(sid)
        if not DIGITS_RE.fullmatch(ts) or not HEX64_RE.fullmatch(sig):
            raise StoreError(401, NOT_SIGNED)
        now = self.server.store.now()
        if abs(now - int(ts)) > cfg['skew_sec']:
            raise StoreError(401, 'the request time is too far from the server clock (%d)' % now)
        good = sign(key or b'\0' * 32, sid if STREAM_RE.fullmatch(sid) else '-', self.command, path, int(ts), body_sha)
        if not hmac.compare_digest(good, sig) or not key:
            raise StoreError(401, NOT_SIGNED)
        return sid, int(ts), sig

    def read_small_body(self, limit=65536):
        n = self.content_length()
        if n is None:
            raise StoreError(411, 'send a Content-Length (no chunked bodies)')
        if n > limit:
            raise StoreError(413, 'body too large')
        if not n:
            return b''
        self.send_continue()
        self.server.set_deadline(self.connection, self.server.cfg['header_sec'])
        self.connection.settimeout(self.server.cfg['header_sec'])
        try:
            data = self.rfile.read(n)
        finally:
            self.server.set_deadline(self.connection, None)
            self.connection.settimeout(self.timeout)
        if len(data) != n:
            raise ConnectionError('short body')
        return data

    def api(self, p):
        store, cfg = self.server.store, self.server.cfg
        close = False
        try:
            if self.command == 'PUT':
                m = API_FILE_RE.fullmatch(p)
                if not m:
                    raise StoreError(404, 'not found')
                close = True                 # (until the body is read, nothing more can follow on this connection)
                return self.put_file(p, m.group(1), m.group(2))
            body_sha = self.headers.get('X-Vrclm-Sha256', '').lower()
            if not HEX64_RE.fullmatch(body_sha):
                raise StoreError(401, NOT_SIGNED)
            close = True
            body = self.read_small_body()
            close = False
            if hashlib.sha256(body).hexdigest() != body_sha:
                raise StoreError(400, 'X-Vrclm-Sha256 does not match the body')
            if self.command == 'GET' and p == '/api/v1/status':
                sid, _, _ = self.verify(p, body_sha)
                return self.reply(200, store.status(sid), headers={'Cache-Control': 'no-store'})
            m = API_ITEM_RE.fullmatch(p)
            if m and self.command == 'GET':
                sid, _, _ = self.verify(p, body_sha)
                return self.reply(200, store.listing(sid, m.group(1)), headers={'Cache-Control': 'no-store'})
            if m and self.command == 'DELETE':
                sid, ts, sig = self.verify(p, body_sha)
                return self.reply(200, store.delete(sid, m.group(1), sig, ts))
            m = API_COMMIT_RE.fullmatch(p)
            if m and self.command == 'POST':
                sid, _, _ = self.verify(p, body_sha)
                return self.reply(200, store.commit(sid, m.group(1)))
            m = API_NOW_RE.fullmatch(p)
            if m and self.command == 'POST':
                if not cfg['same_link']:
                    raise StoreError(404, 'the same link is off on this server (same_link)')
                sid, ts, sig = self.verify(p, body_sha)
                if m.group(1) != sid:
                    raise StoreError(403, 'another stream')
                try:
                    want = json.loads(body.decode('utf-8')).get('item') or ''
                except (ValueError, AttributeError):
                    raise StoreError(400, 'the body must be {"item": "<id>"}')
                if not isinstance(want, str) or (want and not ID_RE.fullmatch(want)):
                    raise StoreError(400, 'the body must be {"item": "<id>"}')
                return self.reply(200, store.set_now(sid, want, sig, ts))
            raise StoreError(404, 'not found')
        except StoreError as e:
            hdr = {'X-Vrclm-Now': str(store.now())} if e.code == 401 else None
            return self.fail(e.code, e.text, close=close or e.code in (411, 413), headers=hdr)

    def put_file(self, p, iid, name):
        store, cfg = self.server.store, self.server.cfg
        length = self.content_length()
        if length is None:
            raise StoreError(411, 'send a Content-Length (no chunked uploads)')
        if length > cfg['max_file_mb'] * MB:
            raise StoreError(413, 'the file is larger than %d MB' % cfg['max_file_mb'])
        want = self.headers.get('X-Vrclm-Sha256', '').lower()
        if not HEX64_RE.fullmatch(want):
            raise StoreError(401, NOT_SIGNED)
        sid, _, _ = self.verify(p, want)
        tmp = store.begin_put(sid, iid, name, length)
        ok, bad = False, None
        try:
            self.send_continue()
            h = hashlib.sha256()
            left, first = length, None
            with open(tmp, 'xb') as f:
                while left:
                    chunk = self.rfile.read(min(262144, left))
                    if not chunk:
                        raise ConnectionError('short upload')
                    if first is None:
                        first = chunk[0]
                    h.update(chunk)
                    f.write(chunk)
                    left -= len(chunk)
            if h.hexdigest() != want:
                bad = 'the file does not match X-Vrclm-Sha256'
            elif name != 'index.m3u8' and first != 0x47:
                bad = 'a segment must be MPEG-TS (its first byte is 0x47)'
            else:
                ok = True
        finally:
            if not ok:
                store.end_put(sid, iid, name, tmp, length, False)
        if bad:
            return self.fail(400, bad)
        store.end_put(sid, iid, name, tmp, length, True)
        return self.reply(201, {'ok': True, 'file': name, 'bytes': length})


def make_server(cfg, store, port=None, bind=None):
    port = cfg['port'] if port is None else port
    bind = cfg['bind'] if bind is None else bind
    handler = type('VrclmHandler', (Handler,), {'timeout': cfg['timeout']})
    if bind:
        fam = socket.AF_INET6 if ':' in bind else socket.AF_INET
        return Server((bind, port), handler, store, cfg, fam)
    if socket.has_ipv6:
        try:
            return Server(('::', port), handler, store, cfg, socket.AF_INET6)
        except OSError:
            pass
    return Server(('0.0.0.0', port), handler, store, cfg, socket.AF_INET)


def cleanup_loop(store, stop):
    while not stop.wait(store.cfg['cleanup_min'] * 60):
        try:
            store.cleanup()
        except Exception as e:
            log('cleanup failed: %s: %s' % (e.__class__.__name__, e))


def main(argv=None):
    ap = argparse.ArgumentParser(description='VRChat Link Maker file service')
    ap.add_argument('--config', required=True)
    ap.add_argument('--state', required=True)
    ap.add_argument('--port', type=int)
    ap.add_argument('--bind')
    ap.add_argument('--check-config', action='store_true')
    a = ap.parse_args(argv)
    try:
        cfg = load_config(a.config)
    except ConfigError as e:
        log('config error: %s' % e)
        return 2
    if a.check_config:
        print('config OK: %d stream(s), port %d, budget %d MB' % (len(cfg['streams']), cfg['port'], cfg['budget_mb']))
        return 0
    os.umask(0o077)
    store = Store(a.state, cfg)
    store.cleanup()
    srv = make_server(cfg, store, a.port, a.bind)
    stop = threading.Event()
    threading.Thread(target=cleanup_loop, args=(store, stop), daemon=True).start()

    def on_term(signum, frame):
        stop.set()
        threading.Thread(target=srv.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, on_term)
    log('vrclm-files %d listening on port %d (%d stream(s), budget %d MB, same link %s)' % (
        VERSION, srv.server_address[1], len(cfg['streams']), cfg['budget_mb'], 'on' if cfg['same_link'] else 'off'))
    try:
        srv.serve_forever(poll_interval=1)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        with store.lock:
            for it in store.items.values():
                if it.dirty:
                    try:
                        store._save_meta(it)
                    except OSError:
                        pass
        srv.server_close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
