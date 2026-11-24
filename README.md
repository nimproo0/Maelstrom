<div align="center">

# Maeleström

**A self-hosted media downloader that lives in your terminal.**

One script. No Python. No Node. Nothing to install or babysit.

[![Version](https://img.shields.io/badge/version-1.0-orange)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()
[![Windows](https://img.shields.io/badge/Windows-.bat-0078D6?logo=windows&logoColor=white)]()
[![Linux](https://img.shields.io/badge/Linux-.sh-FCC624?logo=linux&logoColor=black)]()

</div>

---

## What is this?

Maeleström is a downloader for [yt-dlp](https://github.com/yt-dlp/yt-dlp) with a proper interface over it. Instead of memorizing flags, you get a clean TUI right in your terminal: pick a format, paste your links, watch the progress bars. It can also open a small web server, so you can open it from your phone's browser, paste a link there, and let your PC do the download.

Under the hood, it's mostly glue around tools that already do the hard work:

| Tool | Role |
| --- | --- |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Downloads from 1,700+ sites |
| [ffmpeg](https://ffmpeg.org) | Merging, converting, metadata, 4K upscale |

Everything else is built in: the Windows version is a single `.bat` file with embedded PowerShell and C# (including its own QR code encoder), and the Linux version is a single `.sh` file.

## Features

- **Terminal UI, not raw flags.** Menus, live progress bars with speed and ETA, and a preview card (thumbnail, title, channel, duration, site) before you commit to a download.
- **Tube mode, in ten languages.** French, English, Spanish, Italian, Portuguese, German, Russian, Arabic, Chinese, Hindi — detected automatically.
- **Phone mode.** Launch it, scan the QR code, and you get a responsive web page on your phone. Paste a link, pick video or audio, and the download runs on your PC. When it's done, you can grab the file straight from your phone.
- **Video or audio, your call.** Up to 4K or "max available quality" for video, MP3 / WAV / FLAC / M4A (or the original codec untouched) for audio. Thumbnails and metadata embedded by default. The Windows version can even upscale to 4K with ffmpeg (Lanczos + CRF 18).
- **Queues.** Paste a bunch of links (or drag in a `.txt` full of them on Linux) and let it work through them.
- **Extras if you want them.** Whole playlists, cover art, SponsorBlock, browser cookies for private videos.
- **Takes care of itself.** On first run it fetches what it's missing straight from the official GitHub releases (no admin rights needed on Windows, no sudo where it can avoid it on Linux), and keeps yt-dlp up to date.

## Quick start

**Windows** — grab `maelstrom.bat`, double-click it (that's genuinely all):

```bat
maelstrom.bat
```

**Linux** — grab `maelstrom.sh`, then:

```bash
chmod +x maelstrom.sh
./maelstrom.sh
```

Direct download, skipping the menus:

```bash
./maelstrom.sh https://www.youtube.com/watch?v=...
```

## Phone mode

From the settings, pick **Open the port**. Maeleström starts a local server and shows you a URL with a QR code right in the terminal. Scan it with your phone, and you get a mobile-friendly page where you can queue downloads and watch their progress live.

Your phone never downloads anything heavy. It just sends links; the PC handles the rest, and hosts the finished file when you want to retrieve it. On Windows, the file is even deleted from the PC a few minutes after you've saved it on your phone, so nothing piles up.

## FAQ

**The scripts say v6.1 and v6.2, but this is release v1.0. Which is it?**
The internal builds went through several iterations before the first public release, so the version counter is ahead. The public release line starts at 1.0.

**Why is everything in one script file?**
Because it works, and because I like the constraint. One file, no install step, delete it and everything is gone.

**Is this legal?**
Same answer as for yt-dlp itself: it downloads what you could watch anyway. What you do with it is your business; respect copyright and the terms of service of the sites you use.

## Credits

Maeleström is a thin layer of glue and UI on top of genuinely excellent projects, mostly [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [ffmpeg](https://ffmpeg.org), with a nod to [chafa](https://hpjansson.org/chafa/) and [qrencode](https://fukuchi.org/works/qrencode/) on Linux. All credit for the heavy lifting goes to them. The QR encoder embedded in the Windows build is inspired by [Nayuki's algorithm](https://www.nayuki.io/page/qr-code-generator-library).

Docs and user guide: [maelestrom.netlify.app](https://maelestrom.netlify.app)

---

<div align="center">

Maeleström v1.0 · first public release

</div>
