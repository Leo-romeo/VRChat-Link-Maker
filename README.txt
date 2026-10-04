VRChat Link Maker
=================

Turns any video on your PC (or a link to one) into a link that plays in any
VRChat world's video player, for everyone in the instance, with no settings to
change. By default it streams the video to Topaz Chat, a free streaming server
that VRChat trusts. It can also stream from your own PC or your own server.


HOW TO USE
----------
1. Unzip this folder somewhere you'll find it again (the Desktop is fine).
2. Drag video files, or a whole folder of episodes, onto "Make VRChat Link.bat".
   Or double-click the .bat and paste a link to a video, type a title to search
   for it, or press Enter to pick files.
3. First time only: it offers to install ffmpeg (free video toolkit). Say yes.
   If Windows warns you about the .bat file: "More info" > "Run anyway".
4. The window shows your link, and it's already copied to your clipboard.
   In VRChat, switch the world's video player to Stream / Live mode and paste it.
   The link is yours and never changes, so you can save it.
5. The stream goes on the air right away with a "Starting in a moment..."
   screen, so you can put the link into the player at once. The video itself
   starts as soon as the world's player on this PC shows the stream, plus
   3 seconds for everyone else's players, so nobody misses the beginning.
   If VRChat isn't running on this PC, press Space to start.

Use the link exactly as shown, with nothing added. (It used to end in
?retry=-1, but VRChat's player sends that part to the server too, and then
the picture never came. Links saved with it: remove the ?retry=-1.)

If the file has several audio or subtitle tracks, it asks which ones you want
(Enter = its best guess). Subtitles are drawn into the picture, including the
fancy fonts anime releases come with. Picture-based Blu-ray subs and .srt/.ass
files sitting next to the video work too.


ANIME SITES AND WATCH-TOGETHER ROOMS
------------------------------------
Paste a link to one of these like any other link:

  Dream Cast  https://dreamerscast.com/home/release/...   (the voice-over
                                                 team's own site: 1080p)
  AniLiberty  https://anilibria.top/anime/releases/release/...   (AniLibria's
                                                 own site: up to 1080p)
  AnimeVost   https://animevost.org/tip/tv/...  (its own voice-overs, 720p
                                                 where it has it, else 480p)
  YummyAnime  https://ru.yummyani.me/catalog/item/...   (every voice-over,
                                                 several players for each)
  AnimeGO     https://animego.me/anime/...      (a series or a movie page)
  AnimeLib    https://anilib.me/ru/anime/...    (also animelib.org links)
  WPARTY      https://wparty.net/s/...          (a room: it plays what the
                                                 room plays)
  Kinopoisk and Shikimori pages
  Players     Kodik, AniBoom and Sibnet links on their own

- For a series it asks which voice-over (or subtitles) you want, then which
  episodes (Enter = all), then queues them. The preferred voice-overs are at
  the top of the list - Dream Cast, then AniLibria, then official dubs - and
  just Enter takes the first one ("<- auto"). After you picked one, the next
  shows offer that one first. "DubPriority" in config.json sets the preferred
  ones (see SETTINGS).
- To add a series while something is already streaming, press + (it opens a
  second window), or drop the link on the .bat (or paste it into a new window
  of it): that window asks the questions and hands the answers to the running
  stream. Pasted into the streaming window itself, it can't ask, so it queues
  the next 25 episodes with the voice-over you chose last.
- For a WPARTY room it picks up the show, season, episode and voice-over the
  room is on, offers the rest of the season, and can start where the room is.
  It only looks at the room; it never changes anything there.
- The first episode plays straight from the site, so it starts within seconds.
  The next ones download in the background while you watch.
- Besides the players of the page itself, it looks for the same voice-over on
  Dream Cast's own site (1080p), CVH and Alloha (the player WPARTY uses).
  Turbo and Vibix (WPARTY's other players) can't be read: Turbo checks for
  a real browser and Vibix hides its player, so those shows play from the
  other players instead.
- When an episode is on several players (Kodik, AniBoom, Sibnet...), it asks
  once which one to use. "Auto" checks the real picture size of each (a few
  seconds) and takes the sharpest; the next episodes then use that player.
  A show added through the second window is asked about there (unless this
  session already has an answer); with "Auto", its first episode is checked
  when its turn comes.
- If the chosen voice-over or player doesn't work for an episode, it uses
  another one and says so in the window.
- If the stream from a player breaks off mid-episode, it carries on from the
  same spot with another player that has the same voice-over and the same
  length (the backup). Only if there is none does it download the episode.
- These sites change their players now and then. If a link that worked stops
  working, the part to update is VRChatLinkMaker.Sites.ps1.


SEARCHING BY TITLE
------------------
If AnimeGO or AnimeLib don't open where you live, you don't need their links:
just type a title (Russian or English) instead of a link and press Enter.

- Results come from WPARTY's search (films, series and anime, from
  Kinopoisk), YummyAnime, Shikimori (anime) and AnimeLib, then the
  catalogues of AniLiberty, AnimeVost and Dream Cast (each with its own
  voice-over only). If AniLiberty's or AnimeVost's main address doesn't
  answer, their other addresses are tried.
- Pick one, then the season / part, the voice-over (Enter = the preferred
  one) and the episodes.
- It plays through Kodik, Dream Cast's site, AniLiberty's site (Kodik as
  the backup), AnimeVost, CVH or Alloha (if those fail, Collaps). When Kodik doesn't have a voice-over Alloha has (e.g. an official
  dub), that one can be picked too.
- This works on the start screen, while something streams, and in the search
  window that + opens (there you can "play now" or add to the queue).
- English anime: SubsPlease and Nyaa (trusted uploads only) are searched too.
  Their rows come last and are marked [EN]; they are torrents (see below).


TORRENTS (MAGNET LINKS, .TORRENT FILES, ENGLISH ANIME)
------------------------------------------------------
Paste a magnet link, a .torrent file (or a link to one, also a Nyaa page) or
a bare info hash, or pick an [EN] search result. Each episode is downloaded
completely first and then played like a video file on your PC (its own
subtitles and fonts included). Meanwhile the waiting screen shows viewers how
far the download got ("Downloading the next episode: 45% of 700 MB, about
1 min").

- Only download what you are allowed to. The tool ships no trackers and no
  lists; what you download is your own responsibility.
- The first time, it asks to download rqbit, a small free torrent program
  (12.7 MB, Apache-2.0, from github.com/ikatson/rqbit) into the bin\rqbit
  folder. Nothing is installed. Its checksum is verified.
- While an episode downloads it also uploads to other people (that's how
  torrents work), capped at 32 KB/s. When the episode is complete, it stops
  uploading.
- Episodes are deleted after they have played (and when the tool closes).
- Windows may ask whether rqbit may use the network: Cancel is fine, it works
  either way.
- A magnet link or a bare hash first needs the file list from the people
  sharing it (up to a minute). A bare hash is the slowest: a magnet link or a
  .torrent file is faster.
- The PC is kept awake while a torrent downloads (and while the stream is on
  the air).
- Releases with subtitles in many languages (e.g. Erai-raws "MultiSub") get
  Russian subtitles if they have them, else English ("SubLang" below).


WHILE IT'S STREAMING
--------------------
  Space         pause / continue (instant). While it waits for the players,
                Space starts the video right away.
  Left / Right  10 seconds back / forward (with Shift: 30 seconds)
  Up / Down     jump 30 seconds too
  S S           skip to the next video
  Q Q           stop what's playing. The waiting screen stays on and viewers
                stay connected, so you can pick something else.
                Q Q again on the waiting screen ends the stream.
  R R           resync everyone (see below)
  +             open a second window to search / add videos
  F2            open the control window again
  P P           pause / continue (still works too)
  Ctrl+C        end

- Quick presses are never lost, and several "10 seconds back" presses add up.
- Type a title and press Enter to search. Paste a link, or drag files into the
  window, and press Enter to add them. On the waiting screen, Enter alone lets
  you pick files.
- When you pause and continue, it goes on from what viewers actually saw: the
  world's player shows the stream a few seconds behind (it measures how much
  from VRChat's log), and it rewinds by that much.
- R R makes the stream reconnect, so every player jumps to the live picture
  (takes about 10 seconds). The video waits meanwhile, so nobody misses a bit.
- Between videos, and after the last one, viewers see a waiting screen, so
  nobody has to reload. It stops by itself after 15 idle minutes.
- If your internet drops, it reconnects. The video waits on the "Starting in a
  moment..." screen until the world's player on this PC shows the stream
  again, then carries on from where it was.
- If the player on this PC loses the stream while a video plays, the video
  waits until it's back.
- If the player on this PC froze for a while and fell behind the others (ProTV
  reports its position every 5 minutes), everyone reconnects to the live
  picture by itself, like R R. "ResyncWhenBehindSeconds" sets how far behind
  counts (8 s; 0 = off).
- Closed the window mid-episode? Drop the same file(s) on it again and it offers
  to continue where you stopped.
- You can scroll the window up with the mouse wheel to read what it said.
  Everything it says also goes to log.txt next to the .bat (the run before
  that is in log-previous.txt).


THE CONTROL WINDOW
------------------
A small window opens by itself next to the console (F2 opens it again).
It has a live preview of what's being streamed, a seek bar, and buttons:

  << 30s  << 10s  Pause / Continue / Start now  10s >>  30s >>  Next
  Stop (click it twice)
  Up next          the queue
  Add / search...  add videos or search by title
  Watch as viewers see it   opens the real stream in a player on your PC,
                   with the same delay viewers have
  Copy link
  Resync everyone  same as R R
  Settings         server, picture size, upload speed test, new link (while
                   nothing plays; the questions appear in the console window)
  Clock on the stream   shows the video time in a corner of the picture, so
                   you can compare who is behind
  Always on top
On the right under the buttons it shows what the stream carries (picture size,
frames per second, video bitrate, server). Orange means too little bitrate for
that picture size: a smaller size looks sharper.

Space and the arrow keys work in it too. Don't want it?
Set "ControlWindow": false in config.json.


CONTROL IT FROM THE WORLD'S VIDEO PLAYER
----------------------------------------
While you're in the world, you can control the stream from the world's own
video player:

- The TV's own Pause / Play buttons (ProTV, iwaSync3, YamaPlayer) pause and
  continue the stream. After a pause with ProTV's button, every player
  reconnects to the live picture when you press Play, and the video goes on
  for everybody at the same moment (the TV's pause only stops its own buffer,
  so without this it would go on behind the others).
- Your plain link put in again: while paused it continues; while a video plays
  everyone reconnects (like R R).
- Or the link with one of these added at the end:

  <your link>?pause      pause (viewers see a "Paused" screen)
  <your link>?play       continue from where it paused
  <your link>?back       10 seconds back (?back30 = 30 seconds)
  <your link>?fwd        forward
  <your link>?next       skip to the next video
  <your link>?sync       everyone reconnects (like R R); the video waits

  Not yet tried in VRChat since the link lost its ?retry=-1: if the TV shows no
  picture after such a link, put the plain link in again.
The same ending twice in a row counts once (players reload links on their own);
to send it twice, add a number or letter the second time: ?next, then ?next2.

- When a command makes the players reload, the video waits on the "Starting in
  a moment..." screen until the world's player on this PC shows the stream
  again, so nobody misses anything.
- Players with their own pause / play buttons - ProTV, iwaSync3 and YamaPlayer -
  work with those buttons too. ProTV's Stop pauses and its Play continues.
- In ProTV worlds, if the TV lets you pick a low-latency ("LL") player, use
  it for streams: it shows the stream about 1 s behind live, the default HQ
  player 5 s and more, so pauses and commands show up that much later. (Many
  worlds' own TV menus don't offer the choice.)
- Commands are ignored for 20 seconds after you join a world (the world replays
  what its player was doing).
- This works because VRChat writes what the world's player does into its log
  file on this PC, so it only works when VRChat runs on the same PC as this
  tool. Anyone in the instance who loads such a link can use it, too.
- Turn it off with "WorldPlayerControl": false in config.json.


WHERE TO STREAM (TOPAZ, YOUR PC, YOUR VPS)
------------------------------------------
On the start screen (double-click the .bat) type H and press Enter to choose.
It also works typed on the waiting screen.

Topaz Chat (the default)
- Free, and VRChat trusts it, so it plays for everyone in every instance,
  Public ones included, with no settings to change.
- About 1350 kbps of video: from far away Topaz only takes about 1.6 Mbps.

The other choices are NOT trusted by VRChat, which means:
- Everyone who watches, you included, must turn on "Allow Untrusted URLs" in
  VRChat's settings.
- They don't play in Public / Group Public instances (unless the world's
  creator allowlisted the address). Use a Friends+ / Invite instance.

This PC (you host the stream yourself)
- Viewers connect straight to your PC. It downloads MediaMTX (a small free
  streaming server) the first time, after asking, and checks the download.
- Everyone who watches sees your home IP address.
- Your router must pass TCP port 8554 (the PC link, rtspt://) and 1935 (the
  Quest link, rtmp://) to this PC. If you agree, it sets that up with UPnP.
  It also adds a Windows firewall rule (one Windows permission prompt); the
  rule is removed when the tool closes.
- It doesn't work behind CGNAT (many home and mobile lines share one address
  with other customers). It checks this and tells you. Then use a VPS, or the
  IPv6 link (only viewers who have IPv6 can use that one). "Always stream
  through Topaz Chat" in that question remembers the answer, so it doesn't ask
  (or spend seconds checking) at every start.
- For a link that doesn't change with your IP, get a free DuckDNS name and it
  keeps it updated. Without one it uses <your-ip>.sslip.io.
- Each viewer takes about 3 Mbps of your upload.
- Only your link's secret path can be watched, and only the tool itself can
  send (from this PC, with a password made new at every start).
- Everything it set up goes away with it, however the tool closes (even with
  the window's X or Task Manager): MediaMTX and every ffmpeg stop, the firewall
  rule is removed, and the router's forwards (renewed every 30 minutes) run out
  within an hour at the latest.

My VPS (your own rented server - the safer choice)
- This PC sends the stream to your server (encrypted, with a passphrase) and
  viewers connect to the server. Your home IP stays hidden and CGNAT doesn't
  matter. About 4000 kbps.
  1. Type H and choose "My VPS". It writes a "vps-setup" folder with
     README-VPS.txt (the exact steps), install.sh and mediamtx.yml.
  2. Get a server. Free: Oracle Cloud "Always Free" (pick a European home
     region when you sign up; take an Ampere A1 machine, 2 OCPU / 12 GB).
     Not for viewers in Russia: see "Viewers in Russia" below. Paid servers
     cost about 5-6 EUR / USD a month.
  3. Log in to the server as root and paste install.sh in one go.
  4. Type H, choose "My VPS" again and type the server's address. Before
     every start the tool checks the server and says what's wrong, if
     anything (it doesn't answer, doesn't know your link, wrong password).
  5. Press T for a speed test to your server and save the bitrate it suggests.
  6. Start streaming as usual. Everyone who watches, you included, turns on
     "Allow Untrusted URLs".
- The picture is encrypted on its way to the server, but the login that goes
  with it (a user name and password inside SRT's stream id) is not. N (new
  link) changes it.
- Several streams at the same time (one per PC, each with its own link):
  - On the PC that set the server up: H -> "My VPS" -> "Add a stream for
    another PC". Paste the new install.sh on the server again (the streams
    already on it keep working) and send the connection code it shows to the
    other person. The code works like a password: send it privately.
  - On the other PC (a fresh copy from GitHub is fine): paste the code on
    the start screen, or H -> "My VPS" -> paste it instead of an address.
    That PC never runs an install.sh of its own: it would replace the
    server's setup.
  - "Show a connection code" also gives codes for another PC of yours: your
    own link (only one of the two can stream on it at a time) or the whole
    server (that PC can then manage it too, e.g. after reinstalling Windows;
    it gets your link as well). Change the streams on one PC only: the
    server gets the streams of the PC that pasted install.sh last.
  - A code went to the wrong person? "Remove a stream" takes one stream's
    code back, N takes back the code for your own link, and "New passwords
    for every stream" takes back every code (paste install.sh again after
    each of them, then send new codes).
  - All streams share the server's upload (2 streams x 10 viewers x 4 Mbps =
    80 Mbps).

Viewers in Russia (which VPS? do your own research)
- Russian internet providers cut video from the big cloud hosts: Oracle,
  Hetzner, OVH, DigitalOcean, AWS, Google Cloud, Azure, Linode/Akamai and
  others (Topaz too). The player connects, but the picture stays black. Oracle
  Always Free is fine for viewers outside Russia, but not for viewers in
  Russia.
- An example: the author's server at Amnezia Hosting (amnezia.host),
  Netherlands location, about 5.50 USD a month. In October 2026 a small data
  test from 20 test points on Russian home networks (Rostelecom, MTS, Beeline
  and others) got through; a viewing test in VRChat is still to come. This is
  an example, not an endorsement: the author isn't affiliated with it, it can
  change at any time, and its other locations weren't tested.
- Do your own research before you pay. What to look out for:
  - Look up the host's network, not its brand: ipinfo.io/<server IP> shows the
    network (ASN) and its name. Small shops often rent from the big clouds
    above, and "anti-DDoS" addresses can belong to such a network too.
  - Avoid the big cloud networks listed above (and resellers on them).
  - Before you commit, ask a friend in Russia to watch a test stream for a few
    minutes with their VPN / WARP off. A ping, an open port or a working login
    to the server proves nothing; only video that keeps playing does.
  - Prefer plans you can pay by the hour or month, or with a refund window,
    and check the current refund terms first.
  - You need a dedicated IPv4 address (not a shared "NAT VPS" address, not
    IPv6 only) and free choice of ports.
  - Check the traffic limit: every viewer downloads the whole stream, about
    2 GB per viewer per hour at 4-5 Mbps.
  - Test again now and then: the providers' lists change.

Custom
- Your own server addresses and links in config.json. For example Twitch:
  VRChat trusts it and it plays in Public instances, but the stream is public
  there and anime may get taken down for copyright.

More keys on the start screen:
- T  upload speed test for the host you picked (Topaz: a 30-second test stream
     with a throwaway key; VPS: to your server; this PC: your upload). It
     suggests a bitrate and can save it.
- N  new link (new secret key). The old link stops working. My VPS: its
     password changes too; paste install.sh on the server again. A PC that
     streams with a connection code asks whoever manages the server for a
     new code instead.
- V  picture size: Auto (the sharpest the host carries well: 720p on Topaz,
     900p from this PC, 1080p from a VPS) or 360p to 1080p. Also works typed
     on the waiting screen. Changing it makes the players reconnect once.

The video bitrate follows the host by itself: each picture size gets what it
needs, never more than the host takes (Topaz 1350 kbps, this PC 3000, VPS 4000,
or what you saved from the speed test). The line under your link shows what
it uses right now.


LANGUAGE
--------
The window speaks English or Russian (README.ru.txt is this guide in Russian).
The first time you start it, it asks which one (Enter = the one that matches
Windows). To change it later: double-click the .bat, type L and press Enter.
Or set "Language" in config.json. The screens viewers see ("Paused", the
waiting screens) use the same language. S / P / Q work with a Russian keyboard
layout on too, and yes / no questions take Russian answers.
Keep the "lang" folder next to the .bat: the translations live there.

Adding another language: copy lang\ru.json to lang\<code>.json (the two-letter
code, e.g. lang\de.json), open it in Notepad, translate the text on the right
of each line (leave the left side alone, keep {0}, {1}... where they are) and
set "_language" to the language's own name. It then shows up in the language
menu. Anything left out stays in English.


UPDATES
-------
New versions are published on github.com/Leo-romeo/VRChat-Link-Maker. Each
time you start the tool it checks there (a second or less). When there is a
newer version it shows what changed and asks: update now, not now, or skip
that version. Updating downloads it, replaces the program files and starts
again. Your config.json is never touched, so your link stays the same. If
anything goes wrong, the old files are put back.
To turn the check off, add  "Updates": "off"  to config.json.
To install by hand, download the zip from the Releases page and copy its
files over the old ones (config.json isn't in it).


QUEST / ANDROID VIEWERS
-----------------------
The window shows a second link for Quest. The video player sends ONE link to
everybody, so pick the one that matches your group. Some players (like ProTV)
let you enter a second "alternate" link that Quest users get automatically:
put the PC link in the main box and the Quest link in the alternate one.
With Topaz, if the Quest link doesn't play, try the same link with rtsp://
instead of rtmp://.


GOOD TO KNOW
------------
- With Topaz, quality is 720p at about 1.35 Mbps. Topaz Chat allows up to
  2 Mbps of video, but its server is in Japan and from far away only about
  1.6 Mbps in total gets through; more than that makes the stream fall behind
  and stutter for everyone. The speed test (T) shows what gets through for you.
  The encoding is tuned to look as good as possible at that rate (on NVIDIA
  cards it uses the slowest, best-quality settings the card supports). Fine for
  anime and shows, not Blu-ray sharp.
- If the stream still can't keep up (slow upload, or a busy PC), it notices
  within about a minute, lowers the quality a notch and carries on from the
  same spot.
- It's live: viewers can't pause or rewind on their own. You control it.
- If Topaz stutters for you or your friends, see "WHERE TO STREAM" above.
- Anyone who has the link can watch, so don't post it publicly.
- Web links (Twitter/X, Bilibili, Reddit, ...) need yt-dlp, which it offers to
  install the first time. YouTube links already play in VRChat directly.
- A link straight to a video file or stream (ending in .mp4, .mkv, .webm,
  .m4v, .mov, .ts or .m3u8) plays as it is, without yt-dlp. A live .m3u8
  stream plays live: no going back or forward.


SETTINGS (config.json, created next to this file on first run)
--------------------------------------------------------------
All of these are optional.

  VideoKbps   the most video bitrate Topaz / Custom may use. 1350 is right
              for Topaz Chat; higher makes it stutter.
  Bitrate     "auto" (the default): each picture size gets the bitrate it
              needs, at most the host's VideoKbps. "fixed": always the host's
              VideoKbps.
  Height      "auto" (the default) or a number (360, 480, 540, 720, 900,
              1080). V sets it. Use 540 if your PC can't keep up.
  HeightPolicy  "fit" (the default): a size the host's bitrate can't fill is
              sent smaller (1080p on Topaz goes out as 720p, which looks
              sharper at 1350 kbps). "exact" keeps Height as set.
  EncoderArgs "classic" goes back to the old constant-bitrate encoding. The
              default keeps the stream's H.264 header the same all session
              (only the average bitrate drops when it can't keep up), so
              players don't freeze when it switches screens or lowers quality.
  Encoder     "auto" uses your graphics card (NVIDIA/AMD/Intel) when it can,
              "cpu" forces the processor.
  CpuTune     "animation" (the default) tunes CPU encoding for anime; set it
              to "" for live-action shows.
  StreamFps   not set (the default): each connection runs at the frame
              rate of its first video (23.976, 25, 29.97...); later videos
              are converted to it. A number (or "auto" = 23.976) fixes one
              frame rate for the whole session.
  MaxFps      30. Videos above it go out at half rate (50 -> 25);
              set 60 to allow 50/60 fps (needs more upload).
  StartDelaySeconds   3. Extra wait for the other viewers' players before a
              video starts.
  ViewerDelaySeconds  5. How far behind the world's player shows the stream
              (measured automatically when it can be; 2 with ProTV's LL
              player).
  WaitForPlayers      true (the default): a video starts only once the world's
              player on this PC shows the stream. false = start right away.
  ResyncAfterTvPause  3. After a pause of this many seconds with ProTV's own
              button, everyone reconnects when it plays again. 0 = off.
  ResyncWhenBehindSeconds  8. The player on this PC this far behind (it
              froze): everyone reconnects. 0 = off.
  LinkRetry   false (the default). true adds ?retry=-1 to the link again
              (not recommended: the picture may not come).
  Clock       false. true shows the video time in a corner of the picture.
  ControlWindow       true (the default) opens the control window.
  WorldPlayerControl  true (the default) lets the world's video player pause /
              continue / skip (see above). false turns that off.
  Host        "topaz" (the default), "pc", "vps" or "custom". H sets it.
  StreamKey   the secret key behind your link. N makes a new one.
  SelfHost    settings for "This PC": HostName, DuckDnsToken, RtspPort (8554),
              RtmpPort (1935), MaxReaders (10), Upnp, Firewall, Ipv6,
              VideoKbps (3000) and more.
  Vps         settings for "My VPS": Address, VideoKbps (4000), Role
              ("owner" = this PC set the server up, "guest" = it streams with
              a connection code), Streams (the other PCs' streams) and more.
  Language    "auto" (Windows' language if there is a translation for it,
              else English), "en" or "ru". See LANGUAGE above.
  Player      "ask" (the default: asks once per session), "auto" (always the
              sharpest), or one player first: "kodik", "aniboom", "sibnet",
              "cvh", "collaps", "animelib", "alloha", "dreamcast",
              "aniliberty" or "animevost".
  DubPriority the preferred voice-overs, best first: listed at the top when
              it asks, and the first one is what Enter takes. Default:
              ["Dream Cast", "AniLibria", "official"] ("official" = any
              official dub). [] = no preference.
  YummyAppToken  empty (the default). YummyAnime works without one today; if
              it starts asking for an app token, make one on its site
              (yummyani.me/dev/applications) and put it here.
  Torrents    "on" (the default), "off" (torrent links are ignored) or
              "seed" (keeps uploading after an episode is complete).
  TorrentUploadKBps    32. The upload cap while an episode downloads (at
              least 8).
  TorrentDownloadKBps  0 = no cap. A number caps the download speed (KB/s).
  SubLang     "ru,en" (the default): subtitle languages taken without asking,
              best first. "en" = English first.
Delete config.json to get a brand-new link.


IF SOMETHING DOESN'T WORK
-------------------------
- Nothing plays: check the player is in Stream / Live mode. Test the stream on
  your PC with VLC: Media > Open Network Stream > paste the VLC link from the
  window. Or press "Watch as viewers see it" in the control window.
- It keeps saying it's waiting for the world's player: VRChat has to run on
  this PC and the world's player has to be playing your link. Press Space to
  start anyway, or set "WaitForPlayers": false in config.json.
- Plays for you but not for a friend: have them enable "Allow Untrusted URLs"
  in VRChat's settings, or use a Friends+ / Invite instance.
- A "This PC" or "My VPS" link doesn't play: everyone who watches, you
  included, needs "Allow Untrusted URLs" on, and the instance can't be
  Public / Group Public. For "This PC", check that ports 8554 and 1935 reach
  your PC, and whether it said you're behind CGNAT - if so, use a VPS or the
  IPv6 link. Try both the name link and the bare-IP link. Viewers in Russia
  see black: see "Viewers in Russia" above.
- "My VPS" doesn't take the stream: the tool checks the server before every
  start and says why (it doesn't answer, doesn't know your link, wrong
  password, someone else is on your link). A PC that streams with a
  connection code needs a new code from whoever manages the server. On the
  PC that manages the server, paste install.sh on the server again after
  adding or removing streams.
- Someone is behind the others: press R R (or put the plain link in again).
  Turn on "Clock on the stream" in the control window to compare who is where.
- A web link fails to download: update yt-dlp (open PowerShell and run
  winget upgrade yt-dlp.yt-dlp), then try again.
- Stutters for everyone: run the speed test (T), pick 540p with V, and/or
  lower VideoKbps in config.json to 1100.
- An AnimeGO / AnimeLib / WPARTY link stopped working: the site probably
  changed its player. The window says which player failed; it tries the others
  first. If the site doesn't open at all where you are, search by title.
- ?pause / ?next in the world's player does nothing: VRChat must run on this
  PC, and the link has to be exactly your link plus the ending (no extra / or
  #). The window says "(ignored: ...)" when a command doesn't fit, e.g. ?play
  while nothing is paused.
- The TV says it's playing but stays black: make sure the link has nothing
  after it (an old saved link may still end in ?retry=-1).
- Something else: look in log.txt next to the .bat, it has everything the
  window said.
