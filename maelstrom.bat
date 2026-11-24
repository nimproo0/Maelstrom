<# : Maelstrom launcher - ne pas modifier ces lignes
@echo off
chcp 65001 >nul
title Maelstrom
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$f='%~f0'; iex ([IO.File]::ReadAllText($f,[Text.Encoding]::UTF8))"
exit /b
#>

# =====================================================================
#  MAELSTRÖM  ·  téléchargeur universel  ·  v6.1
#  v6.1 : serveur téléphone réécrit en C# multi-thread (plus de gel du TUI),
#  page mobile chaleureuse, fichiers préparés sur le PC puis effacés après envoi.
#  Nouveau : serveur web local (Paramètres → Ouvrir le port) pour piloter
#  les téléchargements depuis un téléphone sur le même Wi-Fi.
#  TUI de téléchargement (yt-dlp + ffmpeg) — un seul fichier .bat
# =====================================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Drawing, System.Web.Extensions, System.Windows.Forms, System.IO.Compression, System.IO.Compression.FileSystem

$App = @{ Name = 'Maelström'; Ver = '6.1'; Notice = 'https://maelestrom.netlify.app/#/capabilities' }
$Root    = Join-Path $env:LOCALAPPDATA 'Maelstrom'
$Bin     = Join-Path $Root 'bin'
$Tmp     = Join-Path $env:TEMP 'Maelstrom'
$CfgFile = Join-Path $Root 'settings.json'
$YtUrl   = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
$FfUrl   = 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
New-Item -ItemType Directory -Force -Path $Root, $Bin, $Tmp | Out-Null

# ---------------------------------------------------------------------
#  Code natif : activation des couleurs ANSI + générateur de QR code
# ---------------------------------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class MsNative {
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
    public static bool EnableVT() {
        IntPtr h = GetStdHandle(-11); uint m;
        if (!GetConsoleMode(h, out m)) return false;
        return SetConsoleMode(h, m | 0x0004);
    }
}
'@

# Encodeur QR compilé à part : s'il échoue, seul le menu Notice est touché
try { Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;

// Encodeur QR minimal (mode octet, correction M) inspiré de l'algorithme de Nayuki
public static class MsQr {
    static readonly int[] EccM = {-1,10,16,26,18,24,16,18,22,22,26,30,22,22,24,24,28,28,26,26,26,26,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28};
    static readonly int[] BlkM = {-1,1,1,1,2,2,4,4,4,5,5,5,8,9,9,10,10,11,13,14,16,17,17,18,20,21,23,25,26,28,29,31,33,35,37,38,40,43,45,47,49};
    static int size; static bool[,] mod; static bool[,] fn;

    static int NumRaw(int v) { int r = (16*v+128)*v+64; if (v >= 2) { int n = v/7+2; r -= (25*n-10)*n-55; if (v >= 7) r -= 36; } return r; }
    static int NumData(int v) { return NumRaw(v)/8 - EccM[v]*BlkM[v]; }
    static void Add(List<bool> b, int val, int len) { for (int i = len-1; i >= 0; i--) b.Add(((val >> i) & 1) != 0); }
    static bool Bit(long x, int i) { return ((x >> i) & 1) != 0; }
    static void Set(int x, int y, bool d) { mod[y,x] = d; fn[y,x] = true; }

    public static bool[,] Encode(string text) {
        byte[] data = Encoding.UTF8.GetBytes(text);
 int ver = 1;
 for (; ver <= 40; ver++) { int cc = ver < 10 ? 8 : 16; if (4 + cc + data.Length*8 <= NumData(ver)*8) break; }
 if (ver > 40) throw new ArgumentException("Texte trop long");
        int cap = NumData(ver)*8;
        List<bool> bb = new List<bool>();
        Add(bb, 4, 4); Add(bb, data.Length, ver < 10 ? 8 : 16);
 foreach (byte x in data) Add(bb, x, 8);
 Add(bb, 0, Math.Min(4, cap - bb.Count));
 Add(bb, 0, (8 - bb.Count % 8) % 8);
        for (int p = 0xEC; bb.Count < cap; p ^= 0xEC ^ 0x11) Add(bb, p, 8);
        byte[] cw = new byte[bb.Count/8];
        for (int i = 0; i < bb.Count; i++) if (bb[i]) cw[i >> 3] |= (byte)(1 << (7 - (i & 7)));
        byte[] all = Interleave(cw, ver);
        size = ver*4+17; mod = new bool[size,size]; fn = new bool[size,size];
 DrawFunctions(ver);
 DrawCodewords(all);
        int best = 0; long bestP = long.MaxValue;
        for (int m = 0; m < 8; m++) { Mask(m); DrawFormat(m); long p = Penalty(); if (p < bestP) { bestP = p; best = m; } Mask(m); }
        Mask(best); DrawFormat(best);
        return mod;
    }

    static byte[] Interleave(byte[] data, int ver) {
        int nb = BlkM[ver], ecl = EccM[ver], raw = NumRaw(ver)/8;
        int nShort = nb - raw % nb, shortLen = raw / nb;
 byte[][] blocks = new byte[nb][];
        byte[] div = RsDivisor(ecl);
        for (int i = 0, k = 0; i < nb; i++) {
     int dl = shortLen - ecl + (i < nShort ? 0 : 1);
     byte[] dat = new byte[dl]; Array.Copy(data, k, dat, 0, dl); k += dl;
     byte[] blk = new byte[shortLen+1]; Array.Copy(dat, blk, dl);
     byte[] ecc = RsRem(dat, div); Array.Copy(ecc, 0, blk, blk.Length - ecl, ecl);
     blocks[i] = blk;
        }
        byte[] res = new byte[raw];
        for (int i = 0, k = 0; i < blocks[0].Length; i++)
     for (int j = 0; j < nb; j++)
  if (i != shortLen - ecl || j >= nShort) { res[k] = blocks[j][i]; k++; }
        return res;
    }
    static int Mul(int x, int y) { int z = 0; for (int i = 7; i >= 0; i--) { z = (z << 1) ^ ((z >> 7) * 0x11D); z ^= ((y >> i) & 1) * x; } return z; }
    static byte[] RsDivisor(int deg) {
 byte[] r = new byte[deg]; r[deg-1] = 1; int root = 1;
 for (int i = 0; i < deg; i++) {
     for (int j = 0; j < deg; j++) { r[j] = (byte)Mul(r[j], root); if (j+1 < deg) r[j] ^= r[j+1]; }
     root = Mul(root, 2);
        }
        return r;
    }
    static byte[] RsRem(byte[] data, byte[] div) {
 byte[] r = new byte[div.Length];
 foreach (byte b in data) {
     int f = (b ^ r[0]) & 0xFF;
     Array.Copy(r, 1, r, 0, r.Length-1); r[r.Length-1] = 0;
     for (int i = 0; i < r.Length; i++) r[i] ^= (byte)Mul(div[i], f);
        }
        return r;
    }
    static void DrawFunctions(int ver) {
 for (int i = 0; i < size; i++) { Set(6, i, i % 2 == 0); Set(i, 6, i % 2 == 0); }
        Finder(3, 3); Finder(size-4, 3); Finder(3, size-4);
        int[] al = AlignPos(ver); int n = al.Length;
        for (int i = 0; i < n; i++) for (int j = 0; j < n; j++) {
     if ((i == 0 && j == 0) || (i == 0 && j == n-1) || (i == n-1 && j == 0)) continue;
     Align(al[i], al[j]);
        }
        DrawFormat(0); DrawVersion(ver);
    }
    static void Finder(int x, int y) {
        for (int dy = -4; dy <= 4; dy++) for (int dx = -4; dx <= 4; dx++) {
     int d = Math.Max(Math.Abs(dx), Math.Abs(dy)); int xx = x+dx, yy = y+dy;
     if (xx >= 0 && xx < size && yy >= 0 && yy < size) Set(xx, yy, d != 2 && d != 4);
 }
    }
    static void Align(int x, int y) {
        for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) Set(x+dx, y+dy, Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1);
    }
    static int[] AlignPos(int ver) {
 if (ver == 1) return new int[0];
 int n = ver/7+2; int step = (ver*8 + n*3 + 5) / (n*4 - 4) * 2;
        int[] r = new int[n]; r[0] = 6;
 for (int i = n-1, pos = size-7; i >= 1; i--, pos -= step) r[i] = pos;
        return r;
    }
    static void DrawFormat(int mask) {
        int data = (0 << 3) | mask; int rem = data;
        for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
        int bits = ((data << 10) | rem) ^ 0x5412;
 for (int i = 0; i <= 5; i++) Set(8, i, Bit(bits, i));
 Set(8, 7, Bit(bits, 6)); Set(8, 8, Bit(bits, 7)); Set(7, 8, Bit(bits, 8));
 for (int i = 9; i < 15; i++) Set(14-i, 8, Bit(bits, i));
        for (int i = 0; i < 8; i++) Set(size-1-i, 8, Bit(bits, i));
        for (int i = 8; i < 15; i++) Set(8, size-15+i, Bit(bits, i));
        Set(8, size-8, true);
    }
    static void DrawVersion(int ver) {
        if (ver < 7) return;
        int rem = ver; for (int i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        int bits = (ver << 12) | rem;
 for (int i = 0; i < 18; i++) { bool b = Bit(bits, i); int a = size-11+i%3, c = i/3; Set(a, c, b); Set(c, a, b); }
    }
    static void DrawCodewords(byte[] data) {
 int i = 0;
 for (int right = size-1; right >= 1; right -= 2) {
     if (right == 6) right = 5;
            for (int vert = 0; vert < size; vert++) for (int j = 0; j < 2; j++) {
  int x = right - j; bool up = ((right + 1) & 2) == 0; int y = up ? size-1-vert : vert;
  if (!fn[y,x] && i < data.Length*8) { mod[y,x] = Bit(data[i >> 3], 7 - (i & 7)); i++; }
     }
        }
    }
    static void Mask(int m) {
        for (int y = 0; y < size; y++) for (int x = 0; x < size; x++) {
            bool inv;
     switch (m) {
         case 0: inv = (x+y) % 2 == 0; break;
  case 1: inv = y % 2 == 0; break;
  case 2: inv = x % 3 == 0; break;
         case 3: inv = (x+y) % 3 == 0; break;
  case 4: inv = (x/3 + y/2) % 2 == 0; break;
         case 5: inv = x*y % 2 + x*y % 3 == 0; break;
         case 6: inv = (x*y % 2 + x*y % 3) % 2 == 0; break;
  default: inv = ((x+y) % 2 + x*y % 3) % 2 == 0; break;
            }
     if (inv && !fn[y,x]) mod[y,x] = !mod[y,x];
        }
    }
    static long Penalty() {
 long p = 0;
 for (int y = 0; y < size; y++) { int run = 1; for (int x = 1; x < size; x++) { if (mod[y,x] == mod[y,x-1]) { run++; if (run == 5) p += 3; else if (run > 5) p++; } else run = 1; } }
        for (int x = 0; x < size; x++) { int run = 1; for (int y = 1; y < size; y++) { if (mod[y,x] == mod[y-1,x]) { run++; if (run == 5) p += 3; else if (run > 5) p++; } else run = 1; } }
        for (int y = 0; y < size-1; y++) for (int x = 0; x < size-1; x++) { bool c = mod[y,x]; if (c == mod[y,x+1] && c == mod[y+1,x] && c == mod[y+1,x+1]) p += 3; }
        int dark = 0; foreach (bool b in mod) if (b) dark++;
 int total = size*size; int k = (Math.Abs(dark*20 - total*10) + total - 1) / total - 1;
        return p + k*10;
    }
}
'@ } catch {}

# ---------------------------------------------------------------------
#  Couleurs & écriture
# ---------------------------------------------------------------------
$Esc = [char]27
$Rst = $Esc + '[0m'
$Eol = $Esc + '[K'
function Rgb([int]$r, [int]$g, [int]$b) { return $Esc + ('[38;2;{0};{1};{2}m' -f $r, $g, $b) }
$Col = @{
    Hi   = (Rgb 252 242 230); Fg  = (Rgb 226 210 194); Dim  = (Rgb 156 136 120)
    Acc  = (Rgb 244 168 103); Ok  = (Rgb 156 203 142); Err  = (Rgb 240 122 106)
    Warn = (Rgb 255 206 128); Trk = (Rgb 66 50 43);    Line = (Rgb 112 84 70)
}
$SelBg = $Esc + '[48;2;50;33;27m'
# Longueur visible d'une chaîne (sans les codes ANSI)
function Vis([string]$s) { return ($s -replace '\x1b\[[0-9;]*m', '').Length }
# Filet qui s'estompe : cuivre -> fond
function Fade([int]$n) {
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $n; $i++) {
 $t = if ($n -gt 1) { $i / ($n - 1) } else { 0 }
 [void]$sb.Append((Rgb ([int](150 - 110 * $t)) ([int](104 - 76 * $t)) ([int](84 - 60 * $t))) + '─')
    }
    return $sb.ToString() + $Rst
}
# Remplissage dégradé or -> corail pour les barres de progression
function Grad-Run([int]$n, [int]$w) {
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $n; $i++) {
 $t = $i / [Math]::Max(1, $w - 1)
 [void]$sb.Append((Rgb ([int](255 - 23 * $t)) ([int](206 - 94 * $t)) ([int](128 - 18 * $t))) + '━')
    }
    return $sb.ToString()
}
$Spin = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
$St = @{ M = 2; YT = $null; FF = $null; FFDir = $null; LastErr = '' }

function Wr([string]$s) { [Console]::Write($s) }
function Ln([string]$s) { [Console]::Write($s + $Rst + "`r`n") }

# ---------------------------------------------------------------------
#  Logo ASCII (sobre : blanc -> gris, ombres ardoise)
# ---------------------------------------------------------------------
$Glyph = @{
    M = @('███╗   ███╗','████╗ ████║','██╔████╔██║','██║╚██╔╝██║','██║ ╚═╝ ██║','╚═╝     ╚═╝')
    A = @(' █████╗ ','██╔══██╗','███████║','██╔══██║','██║  ██║','╚═╝  ╚═╝')
    E = @('███████╗','██╔════╝','█████╗  ','██╔══╝  ','███████╗','╚══════╝')
    L = @('██╗     ','██║     ','██║     ','██║     ','███████╗','╚══════╝')
    S = @('███████╗','██╔════╝','███████╗','╚════██║','███████║','╚══════╝')
    T = @('████████╗','╚══██╔══╝','   ██║   ','   ██║   ','   ██║   ','   ╚═╝   ')
    R = @('██████╗ ','██╔══██╗','██████╔╝','██╔══██╗','██║  ██║','╚═╝  ╚═╝')
    O = @(' ██████╗ ','██╔═══██╗','██║   ██║','██║   ██║','╚██████╔╝',' ╚═════╝ ')
}
$LogoLines = @(); $LogoPlain = @()
$grad = @(@(255,218,150), @(255,198,126), @(248,174,108), @(240,148,100), @(228,124,104), @(212,104,118))
$shadow = Rgb 120 74 62
for ($gy = 0; $gy -lt 6; $gy++) {
    $rowTxt = ''
    foreach ($ch in 'MAELSTROM'.ToCharArray()) {
        $gl = $Glyph[[string]$ch]
        $wmax = ($gl | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
        $rowTxt += $gl[$gy].PadRight($wmax)
    }
    $LogoPlain += $rowTxt
    $fill = Rgb $grad[$gy][0] $grad[$gy][1] $grad[$gy][2]
    $sb = New-Object Text.StringBuilder; $cur = ''
    foreach ($ch in $rowTxt.ToCharArray()) {
        $k = if ($ch -eq [char]'█') { 'f' } elseif ($ch -eq [char]' ') { $cur } else { 's' }
        if ($k -ne $cur) { if ($k -eq 'f') { [void]$sb.Append($fill) } else { [void]$sb.Append($shadow) }; $cur = $k }
        [void]$sb.Append($ch)
    }
    $LogoLines += $sb.ToString()
}

# ---------------------------------------------------------------------
#  Langues (10)
# ---------------------------------------------------------------------
$Langs = [ordered]@{ fr='Français'; en='English'; es='Español'; it='Italiano'; pt='Português'; de='Deutsch'; ru='Русский'; ar='العربية'; zh='中文'; hi='हिन्दी' }
$L10n = @{}
$L10n.fr = @'
tag=Téléchargeur universel
m_dl=Télécharger un lien
m_queue=File d'attente (plusieurs liens)
m_settings=Paramètres
m_tools=Outils
m_open=Ouvrir le dossier de téléchargement
m_quit=Quitter
bye=À bientôt !
menu=Menu principal
nav=↑↓ naviguer  ·  Entrée valider  ·  Échap retour
paste=Collez le lien puis Entrée (vide = retour)
analyzing=Analyse du lien…  (Échap = annuler)
analyze_fail=Impossible d'analyser ce lien.
choose_type=Que voulez-vous télécharger ?
t_video=Vidéo
t_audio=Audio / musique
choose_q=Qualité vidéo
q_max=Maximum disponible
q_up=Upscale 4K avec ffmpeg (agrandi, sans vrais détails en plus)
choose_a=Format audio
a_best=Original — meilleure qualité, sans conversion
a_mp3=MP3 320 kb/s — compatible partout
a_wav=WAV — non compressé (fichier lourd)
a_flac=FLAC — sans perte, plus léger que le WAV
a_m4a=M4A / AAC
source=Source
dl=Téléchargement
channel=Chaîne
duration=Durée
site=Site
format=Format
folder=Dossier
stream=Flux
item=Élément
finalizing=Finalisation (fusion / conversion)…
upscaling=Upscale 4K en cours…
esc=Échap = annuler
done=Terminé !
cancelled=Annulé.
failed=Échec du téléchargement.
done_hint=Entrée = retour  ·  Espace = afficher dans le dossier
anykey=Appuyez sur une touche…
q_title=File d'attente
q_paste=Collez vos liens, un par ligne. Ligne vide = lancer.
q_count={0} lien(s) dans la file
q_sum={0} réussi(s), {1} échec(s)
s_lang=Langue
s_folder=Dossier de téléchargement
s_vq=Qualité vidéo par défaut (file)
s_af=Format audio par défaut (file)
s_thumb=Aperçu de la vignette
s_pl=Télécharger les playlists entières
s_cover=Intégrer la pochette
s_notice=Afficher la notice (QR code)
back=Retour
on=Oui
off=Non
pick=Choisissez le dossier de téléchargement
t_yt=Installer / réparer yt-dlp
t_ff=Installer / réparer ffmpeg
t_up=Mettre à jour yt-dlp
need=Manquant : {0}. Installer maintenant ?
inst_yes=Oui, installer
inst_no=Plus tard
getting=Téléchargement de {0}…
installed={0} installé.
inst_fail=Installation impossible : {0}
notice=Notice de Maelström
scan=Scannez ce QR code avec votre téléphone
notice_hint=Entrée = ouvrir dans le navigateur  ·  Échap = retour
s_web=Ouvrir le port (accès téléphone)
w_title=Accès téléphone  ·  serveur local
w_scan=Scannez ce QR code avec le téléphone
w_same=Le téléphone doit être connecté au même Wi-Fi que ce PC.
w_fw=Si Windows demande l'accès réseau, cochez « Réseaux privés » puis Autoriser.
w_listen=En écoute sur le port {0}
w_stats={0} fichier(s) envoyé(s)
w_conn=Appareil connecté : {0}
w_noconn=Aucun appareil connecté pour l'instant
w_wait=En attente d'un lien envoyé depuis le téléphone…
w_send=Envoi au téléphone : {0}
w_hint=Entrée = ouvrir sur ce PC  ·  Échap = fermer le port
w_fail=Impossible d'ouvrir le port.
pl={0} éléments
unit=o
'@
$L10n.en = @'
tag=Universal downloader
m_dl=Download a link
m_queue=Download queue (several links)
m_settings=Settings
m_tools=Tools
m_open=Open download folder
m_quit=Quit
bye=See you soon!
menu=Main menu
nav=↑↓ move  ·  Enter select  ·  Esc back
paste=Paste the link and press Enter (empty = back)
analyzing=Analyzing link…  (Esc = cancel)
analyze_fail=Could not analyze this link.
choose_type=What do you want to download?
t_video=Video
t_audio=Audio / music
choose_q=Video quality
q_max=Best available
q_up=Upscale to 4K with ffmpeg (enlarged, no real extra detail)
choose_a=Audio format
a_best=Original — best quality, no conversion
a_mp3=MP3 320 kb/s — plays everywhere
a_wav=WAV — uncompressed (large file)
a_flac=FLAC — lossless, smaller than WAV
a_m4a=M4A / AAC
source=Source
dl=Downloading
channel=Channel
duration=Duration
site=Site
format=Format
folder=Folder
stream=Stream
item=Item
finalizing=Finalizing (merge / conversion)…
upscaling=Upscaling to 4K…
esc=Esc = cancel
done=Done!
cancelled=Cancelled.
failed=Download failed.
done_hint=Enter = back  ·  Space = show in folder
anykey=Press any key…
q_title=Download queue
q_paste=Paste your links, one per line. Empty line = start.
q_count={0} link(s) in queue
q_sum={0} succeeded, {1} failed
s_lang=Language
s_folder=Download folder
s_vq=Default video quality (queue)
s_af=Default audio format (queue)
s_thumb=Thumbnail preview
s_pl=Download whole playlists
s_cover=Embed cover art
s_notice=Show the guide (QR code)
back=Back
on=On
off=Off
pick=Choose the download folder
t_yt=Install / repair yt-dlp
t_ff=Install / repair ffmpeg
t_up=Update yt-dlp
need=Missing: {0}. Install now?
inst_yes=Yes, install
inst_no=Later
getting=Downloading {0}…
installed={0} installed.
inst_fail=Installation failed: {0}
notice=Maelström guide
scan=Scan this QR code with your phone
notice_hint=Enter = open in browser  ·  Esc = back
s_web=Open the port (phone access)
w_title=Phone access  ·  local server
w_scan=Scan this QR code with your phone
w_same=The phone must be on the same Wi-Fi as this PC.
w_fw=If Windows asks for network access, tick "Private networks" then Allow.
w_listen=Listening on port {0}
w_stats={0} file(s) sent
w_conn=Device connected: {0}
w_noconn=No device connected yet
w_wait=Waiting for a link sent from the phone…
w_send=Sending to phone: {0}
w_hint=Enter = open on this PC  ·  Esc = close the port
w_fail=Could not open the port.
pl={0} items
unit=B
'@
$L10n.es = @'
tag=Descargador universal
m_dl=Descargar un enlace
m_queue=Cola de descargas (varios enlaces)
m_settings=Ajustes
m_tools=Herramientas
m_open=Abrir la carpeta de descargas
m_quit=Salir
bye=¡Hasta pronto!
menu=Menú principal
nav=↑↓ moverse  ·  Intro elegir  ·  Esc volver
paste=Pega el enlace y pulsa Intro (vacío = volver)
analyzing=Analizando el enlace…  (Esc = cancelar)
analyze_fail=No se pudo analizar este enlace.
choose_type=¿Qué quieres descargar?
t_video=Vídeo
t_audio=Audio / música
choose_q=Calidad de vídeo
q_max=Máxima disponible
q_up=Escalar a 4K con ffmpeg (ampliado, sin detalle real extra)
choose_a=Formato de audio
a_best=Original — máxima calidad, sin conversión
a_mp3=MP3 320 kb/s — compatible con todo
a_wav=WAV — sin comprimir (archivo pesado)
a_flac=FLAC — sin pérdida, más ligero que WAV
a_m4a=M4A / AAC
source=Fuente
dl=Descargando
channel=Canal
duration=Duración
site=Sitio
format=Formato
folder=Carpeta
stream=Flujo
item=Elemento
finalizing=Finalizando (unión / conversión)…
upscaling=Escalando a 4K…
esc=Esc = cancelar
done=¡Listo!
cancelled=Cancelado.
failed=La descarga ha fallado.
done_hint=Intro = volver  ·  Espacio = mostrar en la carpeta
anykey=Pulsa una tecla…
q_title=Cola de descargas
q_paste=Pega tus enlaces, uno por línea. Línea vacía = empezar.
q_count={0} enlace(s) en la cola
q_sum={0} correcto(s), {1} fallido(s)
s_lang=Idioma
s_folder=Carpeta de descargas
s_vq=Calidad de vídeo por defecto (cola)
s_af=Formato de audio por defecto (cola)
s_thumb=Vista previa de la miniatura
s_pl=Descargar listas completas
s_cover=Incrustar la portada
s_notice=Mostrar la guía (código QR)
back=Volver
on=Sí
off=No
pick=Elige la carpeta de descargas
t_yt=Instalar / reparar yt-dlp
t_ff=Instalar / reparar ffmpeg
t_up=Actualizar yt-dlp
need=Falta: {0}. ¿Instalar ahora?
inst_yes=Sí, instalar
inst_no=Más tarde
getting=Descargando {0}…
installed={0} instalado.
inst_fail=Instalación imposible: {0}
notice=Guía de Maelström
scan=Escanea este código QR con tu móvil
notice_hint=Intro = abrir en el navegador  ·  Esc = volver
pl={0} elementos
unit=B
'@
$L10n.it = @'
tag=Downloader universale
m_dl=Scarica un link
m_queue=Coda di download (più link)
m_settings=Impostazioni
m_tools=Strumenti
m_open=Apri la cartella dei download
m_quit=Esci
bye=A presto!
menu=Menu principale
nav=↑↓ muoversi  ·  Invio scegliere  ·  Esc indietro
paste=Incolla il link e premi Invio (vuoto = indietro)
analyzing=Analisi del link…  (Esc = annulla)
analyze_fail=Impossibile analizzare questo link.
choose_type=Cosa vuoi scaricare?
t_video=Video
t_audio=Audio / musica
choose_q=Qualità video
q_max=Massima disponibile
q_up=Upscale 4K con ffmpeg (ingrandito, senza veri dettagli in più)
choose_a=Formato audio
a_best=Originale — qualità massima, senza conversione
a_mp3=MP3 320 kb/s — compatibile ovunque
a_wav=WAV — non compresso (file pesante)
a_flac=FLAC — senza perdita, più leggero del WAV
a_m4a=M4A / AAC
source=Sorgente
dl=Download
channel=Canale
duration=Durata
site=Sito
format=Formato
folder=Cartella
stream=Flusso
item=Elemento
finalizing=Finalizzazione (unione / conversione)…
upscaling=Upscale 4K in corso…
esc=Esc = annulla
done=Fatto!
cancelled=Annullato.
failed=Download non riuscito.
done_hint=Invio = indietro  ·  Spazio = mostra nella cartella
anykey=Premi un tasto…
q_title=Coda di download
q_paste=Incolla i link, uno per riga. Riga vuota = avvia.
q_count={0} link in coda
q_sum={0} riusciti, {1} falliti
s_lang=Lingua
s_folder=Cartella dei download
s_vq=Qualità video predefinita (coda)
s_af=Formato audio predefinito (coda)
s_thumb=Anteprima della miniatura
s_pl=Scarica playlist intere
s_cover=Incorpora la copertina
s_notice=Mostra la guida (codice QR)
back=Indietro
on=Sì
off=No
pick=Scegli la cartella dei download
t_yt=Installa / ripara yt-dlp
t_ff=Installa / ripara ffmpeg
t_up=Aggiorna yt-dlp
need=Manca: {0}. Installare ora?
inst_yes=Sì, installa
inst_no=Più tardi
getting=Download di {0}…
installed={0} installato.
inst_fail=Installazione non riuscita: {0}
notice=Guida di Maelström
scan=Scansiona questo codice QR con il telefono
notice_hint=Invio = apri nel browser  ·  Esc = indietro
pl={0} elementi
unit=B
'@
$L10n.pt = @'
tag=Downloader universal
m_dl=Baixar um link
m_queue=Fila de downloads (vários links)
m_settings=Configurações
m_tools=Ferramentas
m_open=Abrir a pasta de downloads
m_quit=Sair
bye=Até logo!
menu=Menu principal
nav=↑↓ mover  ·  Enter escolher  ·  Esc voltar
paste=Cole o link e pressione Enter (vazio = voltar)
analyzing=Analisando o link…  (Esc = cancelar)
analyze_fail=Não foi possível analisar este link.
choose_type=O que você quer baixar?
t_video=Vídeo
t_audio=Áudio / música
choose_q=Qualidade do vídeo
q_max=Máxima disponível
q_up=Upscale 4K com ffmpeg (ampliado, sem detalhes reais a mais)
choose_a=Formato de áudio
a_best=Original — melhor qualidade, sem conversão
a_mp3=MP3 320 kb/s — compatível com tudo
a_wav=WAV — sem compressão (arquivo grande)
a_flac=FLAC — sem perdas, mais leve que WAV
a_m4a=M4A / AAC
source=Fonte
dl=Baixando
channel=Canal
duration=Duração
site=Site
format=Formato
folder=Pasta
stream=Fluxo
item=Item
finalizing=Finalizando (junção / conversão)…
upscaling=Upscale 4K em andamento…
esc=Esc = cancelar
done=Concluído!
cancelled=Cancelado.
failed=Falha no download.
done_hint=Enter = voltar  ·  Espaço = mostrar na pasta
anykey=Pressione uma tecla…
q_title=Fila de downloads
q_paste=Cole seus links, um por linha. Linha vazia = iniciar.
q_count={0} link(s) na fila
q_sum={0} concluído(s), {1} falha(s)
s_lang=Idioma
s_folder=Pasta de downloads
s_vq=Qualidade de vídeo padrão (fila)
s_af=Formato de áudio padrão (fila)
s_thumb=Pré-visualização da miniatura
s_pl=Baixar playlists inteiras
s_cover=Incorporar a capa
s_notice=Mostrar o guia (QR code)
back=Voltar
on=Sim
off=Não
pick=Escolha a pasta de downloads
t_yt=Instalar / reparar yt-dlp
t_ff=Instalar / reparar ffmpeg
t_up=Atualizar yt-dlp
need=Faltando: {0}. Instalar agora?
inst_yes=Sim, instalar
inst_no=Mais tarde
getting=Baixando {0}…
installed={0} instalado.
inst_fail=Falha na instalação: {0}
notice=Guia do Maelström
scan=Escaneie este QR code com o celular
notice_hint=Enter = abrir no navegador  ·  Esc = voltar
pl={0} itens
unit=B
'@
$L10n.de = @'
tag=Universeller Downloader
m_dl=Link herunterladen
m_queue=Warteschlange (mehrere Links)
m_settings=Einstellungen
m_tools=Werkzeuge
m_open=Download-Ordner öffnen
m_quit=Beenden
bye=Bis bald!
menu=Hauptmenü
nav=↑↓ bewegen  ·  Enter wählen  ·  Esc zurück
paste=Link einfügen und Enter drücken (leer = zurück)
analyzing=Link wird analysiert…  (Esc = abbrechen)
analyze_fail=Dieser Link konnte nicht analysiert werden.
choose_type=Was möchtest du herunterladen?
t_video=Video
t_audio=Audio / Musik
choose_q=Videoqualität
q_max=Höchste verfügbare
q_up=Upscale auf 4K mit ffmpeg (vergrößert, keine echten Zusatzdetails)
choose_a=Audioformat
a_best=Original — beste Qualität, ohne Umwandlung
a_mp3=MP3 320 kb/s — überall abspielbar
a_wav=WAV — unkomprimiert (große Datei)
a_flac=FLAC — verlustfrei, kleiner als WAV
a_m4a=M4A / AAC
source=Quelle
dl=Download
channel=Kanal
duration=Dauer
site=Seite
format=Format
folder=Ordner
stream=Stream
item=Element
finalizing=Abschluss (Zusammenführen / Umwandeln)…
upscaling=Upscale auf 4K läuft…
esc=Esc = abbrechen
done=Fertig!
cancelled=Abgebrochen.
failed=Download fehlgeschlagen.
done_hint=Enter = zurück  ·  Leertaste = im Ordner zeigen
anykey=Beliebige Taste drücken…
q_title=Warteschlange
q_paste=Links einfügen, einer pro Zeile. Leere Zeile = starten.
q_count={0} Link(s) in der Warteschlange
q_sum={0} erfolgreich, {1} fehlgeschlagen
s_lang=Sprache
s_folder=Download-Ordner
s_vq=Standard-Videoqualität (Warteschlange)
s_af=Standard-Audioformat (Warteschlange)
s_thumb=Vorschaubild anzeigen
s_pl=Ganze Playlists herunterladen
s_cover=Cover einbetten
s_notice=Anleitung anzeigen (QR-Code)
back=Zurück
on=An
off=Aus
pick=Download-Ordner wählen
t_yt=yt-dlp installieren / reparieren
t_ff=ffmpeg installieren / reparieren
t_up=yt-dlp aktualisieren
need=Fehlt: {0}. Jetzt installieren?
inst_yes=Ja, installieren
inst_no=Später
getting={0} wird heruntergeladen…
installed={0} installiert.
inst_fail=Installation fehlgeschlagen: {0}
notice=Maelström-Anleitung
scan=Scanne diesen QR-Code mit deinem Handy
notice_hint=Enter = im Browser öffnen  ·  Esc = zurück
pl={0} Elemente
unit=B
'@
$L10n.ru = @'
tag=Универсальный загрузчик
m_dl=Скачать по ссылке
m_queue=Очередь загрузок (несколько ссылок)
m_settings=Настройки
m_tools=Инструменты
m_open=Открыть папку загрузок
m_quit=Выход
bye=До встречи!
menu=Главное меню
nav=↑↓ выбор  ·  Enter подтвердить  ·  Esc назад
paste=Вставьте ссылку и нажмите Enter (пусто = назад)
analyzing=Анализ ссылки…  (Esc = отмена)
analyze_fail=Не удалось проанализировать ссылку.
choose_type=Что вы хотите скачать?
t_video=Видео
t_audio=Аудио / музыка
choose_q=Качество видео
q_max=Максимальное доступное
q_up=Апскейл до 4K через ffmpeg (увеличение без новых деталей)
choose_a=Формат аудио
a_best=Оригинал — лучшее качество, без конвертации
a_mp3=MP3 320 кбит/с — работает везде
a_wav=WAV — без сжатия (большой файл)
a_flac=FLAC — без потерь, легче, чем WAV
a_m4a=M4A / AAC
source=Источник
dl=Загрузка
channel=Канал
duration=Длительность
site=Сайт
format=Формат
folder=Папка
stream=Поток
item=Элемент
finalizing=Завершение (склейка / конвертация)…
upscaling=Апскейл до 4K…
esc=Esc = отмена
done=Готово!
cancelled=Отменено.
failed=Ошибка загрузки.
done_hint=Enter = назад  ·  Пробел = показать в папке
anykey=Нажмите любую клавишу…
q_title=Очередь загрузок
q_paste=Вставляйте ссылки по одной на строку. Пустая строка = старт.
q_count=Ссылок в очереди: {0}
q_sum=Успешно: {0}, ошибок: {1}
s_lang=Язык
s_folder=Папка загрузок
s_vq=Качество видео по умолчанию (очередь)
s_af=Формат аудио по умолчанию (очередь)
s_thumb=Превью обложки
s_pl=Скачивать плейлисты целиком
s_cover=Встраивать обложку
s_notice=Показать инструкцию (QR-код)
back=Назад
on=Вкл
off=Выкл
pick=Выберите папку загрузок
t_yt=Установить / восстановить yt-dlp
t_ff=Установить / восстановить ffmpeg
t_up=Обновить yt-dlp
need=Отсутствует: {0}. Установить сейчас?
inst_yes=Да, установить
inst_no=Позже
getting=Загрузка {0}…
installed={0} установлен.
inst_fail=Не удалось установить: {0}
notice=Инструкция Maelström
scan=Отсканируйте QR-код телефоном
notice_hint=Enter = открыть в браузере  ·  Esc = назад
pl=Элементов: {0}
unit=B
'@
$L10n.ar = @'
tag=أداة التنزيل الشاملة
m_dl=تنزيل رابط
m_queue=قائمة الانتظار (عدة روابط)
m_settings=الإعدادات
m_tools=الأدوات
m_open=فتح مجلد التنزيلات
m_quit=خروج
bye=إلى اللقاء!
menu=القائمة الرئيسية
nav=↑↓ تنقّل  ·  Enter اختيار  ·  Esc رجوع
paste=الصق الرابط ثم اضغط Enter (فارغ = رجوع)
analyzing=جارٍ تحليل الرابط…  (Esc = إلغاء)
analyze_fail=تعذّر تحليل هذا الرابط.
choose_type=ماذا تريد أن تنزّل؟
t_video=فيديو
t_audio=صوت / موسيقى
choose_q=جودة الفيديو
q_max=أعلى جودة متاحة
q_up=تكبير إلى 4K عبر ffmpeg (تكبير بلا تفاصيل حقيقية إضافية)
choose_a=صيغة الصوت
a_best=الأصلي — أفضل جودة، بدون تحويل
a_mp3=MP3 320 kb/s — متوافق مع كل الأجهزة
a_wav=WAV — بدون ضغط (ملف كبير)
a_flac=FLAC — بدون فقدان، أخف من WAV
a_m4a=M4A / AAC
source=المصدر
dl=جارٍ التنزيل
channel=القناة
duration=المدة
site=الموقع
format=الصيغة
folder=المجلد
stream=المسار
item=العنصر
finalizing=جارٍ الإنهاء (دمج / تحويل)…
upscaling=جارٍ التكبير إلى 4K…
esc=Esc = إلغاء
done=تمّ!
cancelled=أُلغي.
failed=فشل التنزيل.
done_hint=Enter = رجوع  ·  مسافة = إظهار في المجلد
anykey=اضغط أي مفتاح…
q_title=قائمة الانتظار
q_paste=الصق الروابط، رابطًا في كل سطر. سطر فارغ = بدء.
q_count={0} رابط في القائمة
q_sum=نجح {0}، فشل {1}
s_lang=اللغة
s_folder=مجلد التنزيلات
s_vq=جودة الفيديو الافتراضية (القائمة)
s_af=صيغة الصوت الافتراضية (القائمة)
s_thumb=معاينة الصورة المصغّرة
s_pl=تنزيل قوائم التشغيل كاملة
s_cover=تضمين صورة الغلاف
s_notice=عرض الدليل (رمز QR)
back=رجوع
on=نعم
off=لا
pick=اختر مجلد التنزيلات
t_yt=تثبيت / إصلاح yt-dlp
t_ff=تثبيت / إصلاح ffmpeg
t_up=تحديث yt-dlp
need=مفقود: {0}. التثبيت الآن؟
inst_yes=نعم، ثبّت
inst_no=لاحقًا
getting=جارٍ تنزيل {0}…
installed=تم تثبيت {0}.
inst_fail=تعذّر التثبيت: {0}
notice=دليل Maelström
scan=امسح رمز QR هذا بهاتفك
notice_hint=Enter = فتح في المتصفح  ·  Esc = رجوع
pl={0} عنصر
unit=B
'@
$L10n.zh = @'
tag=通用下载器
m_dl=下载链接
m_queue=下载队列（多个链接）
m_settings=设置
m_tools=工具
m_open=打开下载文件夹
m_quit=退出
bye=再见！
menu=主菜单
nav=↑↓ 移动  ·  Enter 确认  ·  Esc 返回
paste=粘贴链接后按 Enter（留空 = 返回）
analyzing=正在分析链接…  （Esc = 取消）
analyze_fail=无法分析此链接。
choose_type=你想下载什么？
t_video=视频
t_audio=音频 / 音乐
choose_q=视频画质
q_max=最高可用画质
q_up=用 ffmpeg 放大到 4K（仅放大，不增加真实细节）
choose_a=音频格式
a_best=原始 — 最佳音质，不转换
a_mp3=MP3 320 kb/s — 兼容所有设备
a_wav=WAV — 无压缩（文件较大）
a_flac=FLAC — 无损，比 WAV 小
a_m4a=M4A / AAC
source=来源
dl=正在下载
channel=频道
duration=时长
site=网站
format=格式
folder=文件夹
stream=流
item=项目
finalizing=正在完成（合并 / 转换）…
upscaling=正在放大到 4K…
esc=Esc = 取消
done=完成！
cancelled=已取消。
failed=下载失败。
done_hint=Enter = 返回  ·  空格 = 在文件夹中显示
anykey=按任意键…
q_title=下载队列
q_paste=每行粘贴一个链接。空行 = 开始。
q_count=队列中有 {0} 个链接
q_sum=成功 {0} 个，失败 {1} 个
s_lang=语言
s_folder=下载文件夹
s_vq=默认视频画质（队列）
s_af=默认音频格式（队列）
s_thumb=缩略图预览
s_pl=下载整个播放列表
s_cover=嵌入封面
s_notice=显示说明（二维码）
back=返回
on=开
off=关
pick=选择下载文件夹
t_yt=安装 / 修复 yt-dlp
t_ff=安装 / 修复 ffmpeg
t_up=更新 yt-dlp
need=缺少：{0}。现在安装吗？
inst_yes=是，安装
inst_no=稍后
getting=正在下载 {0}…
installed={0} 已安装。
inst_fail=安装失败：{0}
notice=Maelström 说明
scan=用手机扫描此二维码
notice_hint=Enter = 在浏览器中打开  ·  Esc = 返回
pl={0} 个项目
unit=B
'@
$L10n.hi = @'
tag=यूनिवर्सल डाउनलोडर
m_dl=लिंक डाउनलोड करें
m_queue=डाउनलोड कतार (कई लिंक)
m_settings=सेटिंग्स
m_tools=टूल्स
m_open=डाउनलोड फ़ोल्डर खोलें
m_quit=बाहर निकलें
bye=फिर मिलेंगे!
menu=मुख्य मेनू
nav=↑↓ चुनें  ·  Enter पुष्टि  ·  Esc वापस
paste=लिंक पेस्ट करें और Enter दबाएँ (खाली = वापस)
analyzing=लिंक का विश्लेषण हो रहा है…  (Esc = रद्द)
analyze_fail=इस लिंक का विश्लेषण नहीं हो सका।
choose_type=आप क्या डाउनलोड करना चाहते हैं?
t_video=वीडियो
t_audio=ऑडियो / संगीत
choose_q=वीडियो गुणवत्ता
q_max=उपलब्ध सर्वोच्च
q_up=ffmpeg से 4K अपस्केल (बड़ा, असली अतिरिक्त विवरण नहीं)
choose_a=ऑडियो फ़ॉर्मेट
a_best=मूल — सर्वोत्तम गुणवत्ता, बिना रूपांतरण
a_mp3=MP3 320 kb/s — हर जगह चलता है
a_wav=WAV — बिना संपीड़न (बड़ी फ़ाइल)
a_flac=FLAC — लॉसलेस, WAV से हल्का
a_m4a=M4A / AAC
source=स्रोत
dl=डाउनलोड हो रहा है
channel=चैनल
duration=अवधि
site=साइट
format=फ़ॉर्मेट
folder=फ़ोल्डर
stream=स्ट्रीम
item=आइटम
finalizing=अंतिम चरण (मर्ज / रूपांतरण)…
upscaling=4K अपस्केल हो रहा है…
esc=Esc = रद्द
done=पूरा हुआ!
cancelled=रद्द किया गया।
failed=डाउनलोड विफल।
done_hint=Enter = वापस  ·  Space = फ़ोल्डर में दिखाएँ
anykey=कोई भी कुंजी दबाएँ…
q_title=डाउनलोड कतार
q_paste=हर पंक्ति में एक लिंक पेस्ट करें। खाली पंक्ति = शुरू।
q_count=कतार में {0} लिंक
q_sum={0} सफल, {1} विफल
s_lang=भाषा
s_folder=डाउनलोड फ़ोल्डर
s_vq=डिफ़ॉल्ट वीडियो गुणवत्ता (कतार)
s_af=डिफ़ॉल्ट ऑडियो फ़ॉर्मेट (कतार)
s_thumb=थंबनेल पूर्वावलोकन
s_pl=पूरी प्लेलिस्ट डाउनलोड करें
s_cover=कवर आर्ट जोड़ें
s_notice=गाइड दिखाएँ (QR कोड)
back=वापस
on=चालू
off=बंद
pick=डाउनलोड फ़ोल्डर चुनें
t_yt=yt-dlp इंस्टॉल / ठीक करें
t_ff=ffmpeg इंस्टॉल / ठीक करें
t_up=yt-dlp अपडेट करें
need={0} उपलब्ध नहीं। अभी इंस्टॉल करें?
inst_yes=हाँ, इंस्टॉल करें
inst_no=बाद में
getting={0} डाउनलोड हो रहा है…
installed={0} इंस्टॉल हो गया।
inst_fail=इंस्टॉल नहीं हो सका: {0}
notice=Maelström गाइड
scan=इस QR कोड को अपने फ़ोन से स्कैन करें
notice_hint=Enter = ब्राउज़र में खोलें  ·  Esc = वापस
pl={0} आइटम
unit=B
'@

$Tr = @{}
foreach ($lk in $L10n.Keys) {
    $h = @{}
    foreach ($line in ($L10n[$lk] -split "`r?`n")) { $i = $line.IndexOf('='); if ($i -gt 0) { $h[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1) } }
    $Tr[$lk] = $h
}

# ---------------------------------------------------------------------
#  Paramètres
# ---------------------------------------------------------------------
$Cfg = @{ lang = ''; out = (Join-Path $env:USERPROFILE 'Downloads'); vq = 'max'; af = 'mp3'; thumb = $true; playlist = $false; cover = $true; port = 8765; webkey = '' }
function Load-Cfg {
    if (Test-Path $CfgFile) {
 try {
            $j = Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
     foreach ($pr in $j.PSObject.Properties) { if ($Cfg.ContainsKey($pr.Name)) { $Cfg[$pr.Name] = $pr.Value } }
        } catch {}
    }
}
function Save-Cfg { try { $Cfg | ConvertTo-Json | Set-Content $CfgFile -Encoding UTF8 } catch {} }

# ---------------------------------------------------------------------
#  Petits utilitaires
# ---------------------------------------------------------------------
function L([string]$k) {
    $d = $Tr[[string]$Cfg.lang]
    if ($d -and $d.ContainsKey($k)) { return $d[$k] }
    if ($Tr['en'].ContainsKey($k)) { return $Tr['en'][$k] }
    return $k
}
function G($d, [string]$k) {
  # JavaScriptSerializer renvoie des Dictionary[string,object] : sous PS 5.1, IDictionary.Contains y est implémenté
  # explicitement et donc invisible -> on passe par ContainsKey, avec repli manuel sur les clés pour les autres types.
  if ($null -eq $d -or [string]::IsNullOrEmpty($k)) { return $null }
  if ($d -is [Collections.Generic.IDictionary[string,object]]) { if ($d.ContainsKey($k)) { return $d[$k] }; return $null }
  if ($d -is [Collections.IDictionary]) { foreach ($x in @($d.Keys)) { if ([string]$x -ceq $k) { return $d[$x] } } }
  return $null
}
function First { foreach ($v in $args) { if ($null -ne $v -and "$v" -ne '') { return $v } }; return $null }
function Trunc([string]$s, [int]$n) { if ($n -lt 2) { return '' }; if ($s.Length -gt $n) { return $s.Substring(0, $n - 1) + '…' }; return $s }
function Short([string]$s) { return ($s -split ' — ')[0] }
function Num($s) { $d = 0.0; if ([double]::TryParse([string]$s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }; return -1.0 }
function Sz([double]$b) {
    $u = L 'unit'
    if ($b -lt 0) { return '?' }
    if ($b -ge 1GB) { return ('{0:N2} G{1}' -f ($b / 1GB), $u) }
    if ($b -ge 1MB) { return ('{0:N1} M{1}' -f ($b / 1MB), $u) }
    return ('{0:N0} K{1}' -f ($b / 1KB), $u)
}
function Dur($sec) {
    $ts = [TimeSpan]::FromSeconds([double]$sec)
    if ($ts.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds) }
    return ('{0}:{1:00}' -f $ts.Minutes, $ts.Seconds)
}
function HL([int]$h) {
    $tag = switch ($h) { 4320 { '8K' } 2160 { '4K' } 1440 { 'QHD' } 1080 { 'Full HD' } 720 { 'HD' } default { '' } }
    if ($tag) { return "${h}p ($tag)" } else { return "${h}p" }
}
function VqLabel($v) { if ("$v" -eq 'max') { return (L 'q_max') }; return (HL ([int]"$v")) }
function AfLabel($v) { return (Short (L "a_$v")) }
function OnOff($b) { if ($b) { return (L 'on') } else { return (L 'off') } }
function Kv($k, $v) { return $k + $Col.Dim + '   ·   ' + $v }
function Wrap([string]$s, [int]$w, [int]$max) {
    $out = @(); $rest = $s
    while ($rest.Length -gt 0 -and $out.Count -lt $max) {
        if ($rest.Length -le $w) { $out += $rest; break }
        if ($out.Count -eq $max - 1) { $out += $rest.Substring(0, $w - 1) + '…'; break }
        $cut = $rest.LastIndexOf(' ', $w); if ($cut -lt ($w / 2)) { $cut = $w }
        $out += $rest.Substring(0, $cut).TrimEnd(); $rest = $rest.Substring($cut).TrimStart()
    }
    return ,$out
}
function Flush-Keys { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } }
function Wait-Key { Flush-Keys; [void][Console]::ReadKey($true) }
function Clean-Tmp {
    if (-not (Test-Path $Tmp)) { New-Item -ItemType Directory -Force -Path $Tmp | Out-Null; return }
    Get-ChildItem -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
function Read-Url {
    try { [Console]::CursorVisible = $true } catch {}
    $s = [Console]::ReadLine()
    try { [Console]::CursorVisible = $false } catch {}
    if ($null -eq $s) { return '' }
    return $s.Trim().Trim('"').Trim()
}

# ---------------------------------------------------------------------
#  Outils (yt-dlp / ffmpeg) — sans winget
# ---------------------------------------------------------------------
function Find-Tool([string]$name) {
    foreach ($d in @($Bin, (Join-Path $env:LOCALAPPDATA 'Vortex\bin'))) { $p = Join-Path $d "$name.exe"; if (Test-Path $p) { return $p } }
    $c = Get-Command "$name.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}
function Refresh-Tools {
    $St.YT = Find-Tool 'yt-dlp'
    $St.FF = Find-Tool 'ffmpeg'
    $St.FFDir = if ($St.FF) { Split-Path $St.FF } else { $null }
}

# ---------------------------------------------------------------------
#  Processus externes
# ---------------------------------------------------------------------
function QArg([string]$s) {
    if ($s.Length -eq 0) { return '""' }
    if ($s -notmatch '[\s"]') { return $s }
    $sb = New-Object Text.StringBuilder; [void]$sb.Append('"'); $bs = 0
    foreach ($c in $s.ToCharArray()) {
        if ($c -eq [char]'\') { $bs++ }
        elseif ($c -eq [char]'"') { [void]$sb.Append([char]92, 2 * $bs + 1); [void]$sb.Append('"'); $bs = 0 }
        else { if ($bs) { [void]$sb.Append([char]92, $bs) }; [void]$sb.Append($c); $bs = 0 }
    }
    if ($bs) { [void]$sb.Append([char]92, 2 * $bs) }
    [void]$sb.Append('"'); return $sb.ToString()
}
function Start-Proc([string]$exe, [string[]]$argList) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (($argList | ForEach-Object { QArg $_ }) -join ' ')
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'
    return [Diagnostics.Process]::Start($psi)
}
function Kill-Tree($p) { try { & taskkill.exe /PID $p.Id /T /F *> $null } catch {} }

# Lit stdout/stderr ligne par ligne sans bloquer, rafraîchit l'écran, gère Échap.
function Pump($p, [scriptblock]$OnLine, [scriptblock]$OnTick) {
    $ppO = $p.StandardOutput; $ppE = $p.StandardError
    $ppTo = $ppO.ReadLineAsync(); $ppTe = $ppE.ReadLineAsync()
    $ppOd = $false; $ppEd = $false
    $ppSw = [Diagnostics.Stopwatch]::StartNew(); $ppLast = -1000; $ppTick = 0
    while (-not ($ppOd -and $ppEd)) {
 $ppBusy = $false
        if (-not $ppOd -and $ppTo.IsCompleted) {
     $ppL = $null; try { $ppL = $ppTo.Result } catch {}
     if ($null -eq $ppL) { $ppOd = $true } else { $null = & $OnLine $ppL $false; $ppTo = $ppO.ReadLineAsync() }
     $ppBusy = $true
        }
        if (-not $ppEd -and $ppTe.IsCompleted) {
     $ppL = $null; try { $ppL = $ppTe.Result } catch {}
     if ($null -eq $ppL) { $ppEd = $true } else { $null = & $OnLine $ppL $true; $ppTe = $ppE.ReadLineAsync() }
     $ppBusy = $true
        }
        while ([Console]::KeyAvailable) {
     $ppK = [Console]::ReadKey($true)
     if ($ppK.Key -eq 'Escape') { Kill-Tree $p; return $true }
        }
        if ($ppSw.ElapsedMilliseconds - $ppLast -ge 90) { $ppLast = $ppSw.ElapsedMilliseconds; $ppTick++; $null = & $OnTick $ppTick }
        if (-not $ppBusy) { Start-Sleep -Milliseconds 25 }
    }
    $p.WaitForExit()
    return $false
}

# ---------------------------------------------------------------------
#  Rendu : en-tête, menus, barre de progression
# ---------------------------------------------------------------------
function Draw-Header([switch]$Compact) {
    [Console]::Clear()
    $w = [Console]::WindowWidth; $h = [Console]::WindowHeight
    $big = (-not $Compact) -and $w -ge 84 -and $h -ge 24
    $St.M = if ($big) { [Math]::Max(2, [int](($w - 80) / 2)) } else { 2 }
    $m = ' ' * $St.M
    # Style "terminal de surveillance" : capitales espacées, séparateurs fins
    $latin = -not (@('ar', 'zh', 'hi') -contains [string]$Cfg.lang)
    $tagTxt = ([string](L 'tag')).ToUpper()
    if ($latin) { $tagTxt = ($tagTxt.ToCharArray() -join ' ') }
    $name = ('MAELSTRÖM'.ToCharArray() -join ' ')
    Ln ''
    if ($big) {
 foreach ($l in $LogoLines) { Ln ($m + $l) }
        $plain = '˚ · ✧ ── ' + $tagTxt + ' ── ✧ · ˚   v' + $App.Ver
        $pad = ' ' * [Math]::Max(0, $St.M + [int]((80 - $plain.Length) / 2))
        Ln ($pad + $Col.Dim + '˚ · ' + $Col.Acc + '✧' + $Col.Line + ' ── ' + $Col.Fg + $tagTxt + $Col.Line + ' ── ' + $Col.Acc + '✧' + $Col.Dim + ' · ˚   ' + $Col.Warn + 'v' + $App.Ver)
        Ln ''
    } else {
        Ln ($m + $Col.Acc + '✦ ' + $Col.Hi + $name + $Col.Line + '   │   ' + $Col.Dim + $tagTxt + $Col.Line + '   │   ' + $Col.Dim + 'v' + $App.Ver)
    }
    $dy = if ($St.YT) { $Col.Ok + '●' } else { $Col.Err + '●' }
    $df = if ($St.FF) { $Col.Ok + '●' } else { $Col.Err + '●' }
    Ln ($m + $Col.Dim + 'yt-dlp ' + $dy + $Col.Dim + '   ffmpeg ' + $df + $Col.Dim + '   │   ' + $Col.Fg + (Trunc $Cfg.out ($w - $St.M - 34)))
    Ln ($m + (Fade ([Math]::Max(10, [Math]::Min(80, $w - 2 * $St.M)))))
    Ln ''
}

function Menu([string]$title, $items, [int]$sel = 0, [string]$sub = '') {
    $items = @($items)
    if ($sel -lt 0 -or $sel -ge $items.Count) { $sel = 0 }
    Draw-Header
    $m = ' ' * $St.M
    $bw = [Math]::Max(30, [Math]::Min(80, [Console]::WindowWidth - 2 * $St.M - 1))
    Ln ($m + $Col.Line + '╭─ ' + $Col.Acc + '✦ ' + $Col.Hi + $title + ' ' + (Fade ([Math]::Max(4, $bw - (Vis $title) - 6))))
    if ($sub) { Ln ($m + $Col.Line + '│  ' + $Col.Dim + (Trunc $sub ($bw - 4))) }
    Ln ($m + $Col.Line + '│')
    $top = [Console]::CursorTop
    $draw = {
        for ($i = 0; $i -lt $items.Count; $i++) {
     [Console]::SetCursorPosition(0, $top + $i)
     $n = if ($i -lt 9) { [string]($i + 1) } else { ' ' }
     if ($i -eq $sel) { $vb = 8 + $n.Length + (Vis ([string]$items[$i])); Wr ($m + $Col.Acc + '┃' + $SelBg + $Col.Acc + ' ❯  ' + $Col.Warn + $n + '   ' + $Col.Hi + $items[$i] + $SelBg + (' ' * [Math]::Max(1, $bw - $vb)) + $Rst + $Eol) }
     else { Wr ($m + $Col.Line + '│' + '    ' + $Col.Dim + $n + '   ' + $Col.Fg + $items[$i] + $Rst + $Eol) }
 }
    }
    & $draw
    [Console]::SetCursorPosition(0, $top + $items.Count)
    Wr ($m + $Col.Line + '│' + $Rst + $Eol)
    [Console]::SetCursorPosition(0, $top + $items.Count + 1)
    $nav = L 'nav'
    Wr ($m + $Col.Line + '╰─ ' + $Col.Dim + $nav + ' ' + (Fade ([Math]::Max(4, $bw - (Vis $nav) - 4))) + $Rst)
    while ($true) {
        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
     'UpArrow'   { $sel = ($sel - 1 + $items.Count) % $items.Count; & $draw }
     'DownArrow' { $sel = ($sel + 1) % $items.Count; & $draw }
     'Home'      { $sel = 0; & $draw }
            'End'       { $sel = $items.Count - 1; & $draw }
     'Enter'     { return $sel }
     'Escape'    { return -1 }
     default {
  if ($k.KeyChar -match '^[1-9]$') { $n = [int][string]$k.KeyChar - 1; if ($n -lt $items.Count) { return $n } }
     }
 }
    }
}

function Bar([double]$frac, [int]$w, [int]$tick) {
    if ($frac -lt 0) {
        $seg = 12; $pos = ($tick % ($w + $seg)) - $seg
        $a = [Math]::Max(0, $pos); $b = [Math]::Min($w, $pos + $seg); if ($b -lt $a) { $b = $a }
        return $Col.Trk + ('━' * $a) + $Col.Acc + ('━' * ($b - $a)) + $Col.Trk + ('━' * ($w - $b)) + $Rst
    }
    $n = [int][Math]::Round([Math]::Min(1, $frac) * $w)
    return (Grad-Run $n $w) + $Col.Trk + ('━' * ($w - $n)) + $Rst
}

function Draw-Progress([int]$row, [double]$frac, [string]$txt, [int]$tick, [string]$hint = $null) {
    if ($null -eq $hint) { $hint = L 'esc' }
    try {
        $m = ' ' * $St.M
 $w = [Math]::Max(20, [Math]::Min(60, [Console]::WindowWidth - $St.M - 12))
 $pct = if ($frac -ge 0) { '{0,5:N1} %' -f ([Math]::Min(1, $frac) * 100) } else { '' }
        [Console]::SetCursorPosition(0, $row);     Wr ($m + (Bar $frac $w $tick) + '  ' + $Col.Hi + $pct + $Rst + $Eol)
        [Console]::SetCursorPosition(0, $row + 1); Wr ($m + $Col.Dim + $txt + $Rst + $Eol)
 [Console]::SetCursorPosition(0, $row + 2); Wr ($m + $Col.Dim + $hint + $Rst + $Eol)
    } catch {}
}

# ---------------------------------------------------------------------
#  Vignette : chargée en mémoire, jamais enregistrée
# ---------------------------------------------------------------------
function Thumb-Urls($info) {
    $list = @()
    $th = G $info 'thumbnails'
    if (-not $th) { $en = G $info 'entries'; if ($en -and @($en).Count -gt 0) { $th = G @($en)[0] 'thumbnails' } }
    if ($th) {
 $sorted = @(@($th) | Sort-Object @{ e = { $p = G $_ 'preference'; if ($null -ne $p) { [double]$p } else { 0 } } }, @{ e = { $w = G $_ 'width'; if ($w) { [double]$w } else { 0 } } } -Descending)
 $list += @($sorted | Where-Object { (G $_ 'url') -match '\.(jpe?g|png)(\?|$)' } | ForEach-Object { G $_ 'url' } | Select-Object -First 3)
        $list += @($sorted | ForEach-Object { G $_ 'url' } | Select-Object -First 1)
    }
    $t1 = G $info 'thumbnail'; if ($t1) { $list += $t1 }
    return @($list | Where-Object { $_ } | Select-Object -Unique)
}

function Load-Img([string]$url) {
    $bytes = $null
    try { $wc = New-Object Net.WebClient; $wc.Headers.Add('User-Agent', 'Mozilla/5.0'); $bytes = $wc.DownloadData($url); $wc.Dispose() } catch { return $null }
    try { $ms = New-Object IO.MemoryStream(, $bytes); return [Drawing.Image]::FromStream($ms) } catch {}
    # Format non lu par Windows (WebP…) : décodage par ffmpeg via des tuyaux, en mémoire
    if ($St.FF) {
        try {
     $psi = New-Object Diagnostics.ProcessStartInfo $St.FF, '-hide_banner -loglevel error -i pipe:0 -frames:v 1 -vf scale=480:-2 -f image2pipe -c:v bmp pipe:1'
     $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
     $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
     $p = [Diagnostics.Process]::Start($psi)
     $out = New-Object IO.MemoryStream
     $copy = $p.StandardOutput.BaseStream.CopyToAsync($out)
     $null = $p.StandardError.ReadToEndAsync()
            $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.Close()
     if (-not $p.WaitForExit(8000)) { try { $p.Kill() } catch {}; return $null }
     $copy.Wait(); $out.Position = 0
     return [Drawing.Image]::FromStream($out)
        } catch {}
    }
    return $null
}

function Render-Img($img, [int]$cols, [int]$rows) {
    $pw = $cols; $ph = $rows * 2
    $bmp = New-Object Drawing.Bitmap $pw, $ph
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $iw = $img.Width; $ih = $img.Height; $ta = $pw / $ph
    if (($iw / $ih) -gt $ta) { $sw = [int]($ih * $ta); $src = New-Object Drawing.Rectangle ([int](($iw - $sw) / 2)), 0, $sw, $ih }
    else { $sh = [int]($iw / $ta); $src = New-Object Drawing.Rectangle 0, ([int](($ih - $sh) / 2)), $iw, $sh }
    $g.DrawImage($img, (New-Object Drawing.Rectangle 0, 0, $pw, $ph), $src, [Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    $lines = New-Object 'System.Collections.Generic.List[string]'
    for ($y = 0; $y -lt $rows; $y++) {
        $sb = New-Object Text.StringBuilder
 for ($x = 0; $x -lt $pw; $x++) {
     $a = $bmp.GetPixel($x, 2 * $y); $b = $bmp.GetPixel($x, 2 * $y + 1)
     [void]$sb.Append(('{0}[38;2;{1};{2};{3};48;2;{4};{5};{6}m▀' -f $Esc, $a.R, $a.G, $a.B, $b.R, $b.G, $b.B))
        }
 [void]$sb.Append($Rst); $lines.Add($sb.ToString())
    }
    $bmp.Dispose()
    return ,$lines.ToArray()
}

function Get-ThumbLines($info, [int]$cols, [int]$rows) {
    foreach ($u in @(Thumb-Urls $info | Select-Object -First 4)) {
        $img = Load-Img $u
        if ($img) { try { return ,(Render-Img $img $cols $rows) } catch {} finally { $img.Dispose() } }
    }
    return $null
}

# ---------------------------------------------------------------------
#  Analyse d'un lien (yt-dlp -J)
# ---------------------------------------------------------------------
function Get-Info([string]$url, [int]$row) {
    $a = @('-J', '--flat-playlist', '--no-warnings', '--ignore-config')
    if (-not $Cfg.playlist) { $a += '--no-playlist' }
    $a += '--', $url
    $p = Start-Proc $St.YT $a
    $gi = @{ out = (New-Object Text.StringBuilder); err = @() }
    $c = Pump $p {
 param($line, $isErr)
        if ($isErr) { if ($line -match 'ERROR') { $gi.err += $line } } else { [void]$gi.out.Append($line) }
    } {
 param($tick)
        try { [Console]::SetCursorPosition(0, $row) } catch {}
        Wr ((' ' * $St.M) + $Col.Acc + $Spin[$tick % $Spin.Count] + '  ' + $Col.Fg + (L 'analyzing') + $Rst + $Eol)
    }
    if ($c) { return 'cancel' }
    $St.LastErr = ($gi.err -join "`n")
    $json = $gi.out.ToString().Trim()
    if (-not $json.StartsWith('{')) { return $null }
    try {
        $ser = New-Object Web.Script.Serialization.JavaScriptSerializer
 $ser.MaxJsonLength = [int]::MaxValue; $ser.RecursionLimit = 512
        return $ser.DeserializeObject($json)
    } catch { return $null }
}

function Heights($info) {
    $set = @{}
    foreach ($f in @(G $info 'formats')) { $hh = G $f 'height'; $vc = G $f 'vcodec'; if ($hh -and $vc -ne 'none') { $set[[int]$hh] = 1 } }
    return @($set.Keys | Sort-Object -Descending)
}
function Audio-Source($info) {
    $best = $null; $bv = -1.0
    foreach ($f in @(G $info 'formats')) {
        $ac = G $f 'acodec'; $vc = G $f 'vcodec'; $abr = G $f 'abr'
 if ($ac -and $ac -ne 'none' -and $vc -eq 'none' -and $abr -and [double]$abr -gt $bv) { $bv = [double]$abr; $best = $f }
    }
    if (-not $best) { return '' }
    $codec = ([string](G $best 'acodec')).Split('.')[0]; if ($codec -eq 'mp4a') { $codec = 'aac' }
    return ('{0}  ·  {1:N0} kb/s' -f $codec, $bv)
}

# ---------------------------------------------------------------------
#  Arguments yt-dlp
# ---------------------------------------------------------------------
function Video-Args([int]$h) {
    $f = if ($h -gt 0) { "bv*[height<=$h]+ba/b[height<=$h]/bv*+ba/b" } else { 'bv*+ba/b' }
    $a = @('-f', $f, '-S', 'res,fps,vcodec:h264,acodec:aac', '--merge-output-format', 'mp4', '--embed-metadata', '--embed-chapters')
    if ($Cfg.cover) { $a += '--embed-thumbnail' }
    return ,$a
}
function Audio-Args([string]$af) {
    $a = @('-f', 'ba/b', '-x')
    switch ($af) {
        'mp3'  { $a += '--audio-format', 'mp3', '--audio-quality', '320K' }
        'wav'  { $a += '--audio-format', 'wav' }
        'flac' { $a += '--audio-format', 'flac' }
        'm4a'  { $a += '--audio-format', 'm4a', '--audio-quality', '0' }
        default { }   # 'best' : codec d'origine, aucune conversion
    }
    $a += '--embed-metadata'
    if ($Cfg.cover -and $af -ne 'wav') { $a += '--embed-thumbnail', '--convert-thumbnails', 'jpg' }
    return ,$a
}

# ---------------------------------------------------------------------
#  Écran de téléchargement (vignette + infos + barre)
# ---------------------------------------------------------------------
function Draw-Job($info, [string]$fmtLabel, [string]$badge) {
    Draw-Header -Compact
    $m = ' ' * $St.M; $w = [Console]::WindowWidth; $wh = [Console]::WindowHeight
    $hdr = $m + $Col.Acc + '⬇  ' + $Col.Hi + (L 'dl')
    if ($badge) { $hdr += $Col.Dim + '   ·   ' + $badge }
    Ln $hdr; Ln ''
    $top = [Console]::CursorTop

    $isPl  = (G $info '_type') -eq 'playlist'
    $title = [string](First (G $info 'title') (G $info 'id') '—')
    $chan  = First (G $info 'uploader') (G $info 'channel') (G $info 'playlist_uploader')
    $dur   = G $info 'duration'
    $site  = First (G $info 'extractor_key') (G $info 'extractor')
    $rows = @()
    if ($chan) { $rows += ,@((L 'channel'), [string]$chan) }
    if ($isPl) { $cnt = First (G $info 'playlist_count') (@(G $info 'entries').Count); $rows += ,@('Playlist', ((L 'pl') -f $cnt)) }
    elseif ($dur) { $rows += ,@((L 'duration'), (Dur $dur)) }
    if ($site) { $rows += ,@((L 'site'), [string]$site) }
    $rows += ,@((L 'format'), $fmtLabel)
    $rows += ,@((L 'folder'), [string]$Cfg.out)
    $lw = ($rows | ForEach-Object { $_[0].Length } | Measure-Object -Maximum).Maximum + 3

    # Taille de la vignette selon la fenêtre (cellule ▀ = 2 pixels carrés)
    $tc = if ($w -ge 130) { 48 } else { 40 }
    $tr = [int]($tc * 9 / 32)
    if ($tr -gt $wh - 15) { $tr = $wh - 15; $tc = [int]($tr * 32 / 9) }
    $thumb = $null
    if ($Cfg.thumb -and $tr -ge 6) {
        [Console]::SetCursorPosition(0, $top); Wr ($m + $Col.Dim + $Spin[0] + '  …')
 $thumb = Get-ThumbLines $info $tc $tr
        [Console]::SetCursorPosition(0, $top); Wr $Eol
    }

    $side = $thumb -and ($w -ge ($St.M + $tc + 40))
    $ix = if ($side) { $St.M + $tc + 3 } else { $St.M }
    $iw = $w - $ix - 2
    $lines = @()
    foreach ($tl in (Wrap $title $iw 2)) { $lines += $Col.Hi + $tl }
    $lines += ''
    foreach ($rw in $rows) { $lines += $Col.Dim + $rw[0].PadRight($lw) + $Col.Fg + (Trunc $rw[1] ($iw - $lw)) }

    if ($side) {
        for ($i = 0; $i -lt $thumb.Count; $i++) { [Console]::SetCursorPosition($St.M, $top + $i); Wr ($thumb[$i] + $Rst) }
 $y0 = $top + [Math]::Max(0, [int](($thumb.Count - $lines.Count) / 2))
        for ($i = 0; $i -lt $lines.Count; $i++) { [Console]::SetCursorPosition($ix, $y0 + $i); Wr ($lines[$i] + $Rst) }
        $bottom = $top + [Math]::Max($thumb.Count, $lines.Count)
    } else {
 $y = $top
        if ($thumb) { foreach ($tl in $thumb) { [Console]::SetCursorPosition($St.M, $y); Wr ($tl + $Rst); $y++ }; $y++ }
 foreach ($l in $lines) { [Console]::SetCursorPosition($ix, $y); Wr ($l + $Rst); $y++ }
        $bottom = $y
    }
    return ($bottom + 1)
}

function Do-Download([string]$url, $info, [string[]]$xargs, [string]$fmtLabel, [string]$badge) {
    Clean-Tmp
    if (-not (Test-Path $Cfg.out)) { New-Item -ItemType Directory -Force -Path $Cfg.out | Out-Null }
    $row = Draw-Job $info $fmtLabel $badge
    $isPl = (G $info '_type') -eq 'playlist'
    $tpl = if ($isPl) { '%(playlist_title).80B/%(playlist_index)03d - %(title).150B.%(ext)s' } else { '%(title).200B.%(ext)s' }
    $a = @('--newline', '--no-colors', '--progress', '--no-warnings', '--ignore-config', '--no-mtime',
           '-P', "home:$($Cfg.out)", '-P', "temp:$Tmp", '-o', $tpl,
    '--progress-template', 'download:MSP|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(info.playlist_index)s|%(info.n_entries)s',
    '--print', 'after_move:MSF|%(filepath)s', '--no-simulate')
    if ($St.FFDir) { $a += '--ffmpeg-location', $St.FFDir }
    if ($Cfg.playlist) { $a += '--yes-playlist' } else { $a += '--no-playlist' }
    $a += $xargs
    $a += '--', $url

    $js = @{ dl = -1.0; tot = -1.0; spd = -1.0; eta = -1.0; stage = 1; prev = 0.0; pi = ''; pn = ''; files = @(); errs = @(); started = $false }
    $p = Start-Proc $St.YT $a
    $cancel = Pump $p {
        param($line, $isErr)
        if ($line.StartsWith('MSP|')) {
     $f = $line.Split('|')
     $d = Num $f[1]; $t = Num $f[2]; if ($t -le 0) { $t = Num $f[3] }
     $pi = if ($f.Count -gt 6) { $f[6] } else { '' }
     if ($pi -ne $js.pi) { $js.pi = $pi; $js.stage = 1; $js.prev = 0.0 }
     elseif ($d -ge 0 -and $js.prev -gt 1048576 -and $d -lt $js.prev * 0.5) { $js.stage++ }
            if ($d -ge 0) { $js.prev = $d }
     $js.dl = $d; $js.tot = $t; $js.spd = Num $f[4]; $js.eta = Num $f[5]
            if ($f.Count -gt 7) { $js.pn = $f[7] }
     $js.started = $true
        }
 elseif ($line.StartsWith('MSF|')) { $js.files += $line.Substring(4).Trim() }
        elseif ($line -match '^ERROR') { $js.errs += $line }
    } {
        param($tick)
        $frac = if ($js.tot -gt 0 -and $js.dl -ge 0) { $js.dl / $js.tot } else { -1 }
 if (-not $js.started) { $txt = $Spin[$tick % $Spin.Count] + '  ' + (L 'dl') + '…' }
        elseif ($frac -ge 0.999) { $txt = $Spin[$tick % $Spin.Count] + '  ' + (L 'finalizing') }
        else {
     $parts = @()
            if ($js.dl -ge 0) { $s = Sz $js.dl; if ($js.tot -gt 0) { $s += ' / ' + (Sz $js.tot) }; $parts += $s }
     if ($js.spd -gt 0) { $parts += (Sz $js.spd) + '/s' }
     if ($js.eta -ge 0) { $parts += 'ETA ' + (Dur $js.eta) }
     $txt = $parts -join '  ·  '
        }
        if ($js.stage -gt 1) { $txt += '  ·  ' + (L 'stream') + ' ' + $js.stage }
        if ($js.pi -and $js.pi -ne 'NA') { $txt += '  ·  ' + (L 'item') + ' ' + $js.pi; if ($js.pn -and $js.pn -ne 'NA') { $txt += '/' + $js.pn } }
        Draw-Progress $row $frac $txt $tick
    }

    if ($cancel) {
 Start-Sleep -Milliseconds 400; Clean-Tmp
        return @{ ok = $false; cancelled = $true; files = @(); errs = @(); row = $row + 2 }
    }
    $ok = ($p.ExitCode -eq 0) -or ($isPl -and $js.files.Count -gt 0)
    if ($ok) { Draw-Progress $row 1 '' 0 ' ' }
    Clean-Tmp
    return @{ ok = $ok; cancelled = $false; files = $js.files; errs = $js.errs; row = $row + 2 }
}

# Upscale ffmpeg (Lanczos + x264 CRF 18) : agrandit le petit côté à 2160 px
function Do-Upscale([string]$file, $dur, [int]$row) {
    $dir = Split-Path $file; $base = [IO.Path]::GetFileNameWithoutExtension($file)
    $final = Join-Path $dir ($base + ' [4K].mp4')
    $tmpOut = Join-Path $Tmp ('up_' + [guid]::NewGuid().ToString('N') + '.mp4')
    $vf = "scale='if(gt(iw,ih),-2,2160)':'if(gt(iw,ih),2160,-2)':flags=lanczos"
    $a = @('-y', '-hide_banner', '-nostats', '-loglevel', 'error', '-i', $file, '-vf', $vf,
    '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-pix_fmt', 'yuv420p', '-c:a', 'copy',
    '-movflags', '+faststart', '-progress', 'pipe:1', $tmpOut)
    $total = if ($dur) { [double]$dur } else { 0.0 }
    $us = @{ t = 0.0; spd = '' }
    $p = Start-Proc $St.FF $a
    $cancel = Pump $p {
        param($line, $isErr)
 if (-not $isErr) {
     if ($line -match '^out_time_us=(\d+)') { $us.t = [double]$Matches[1] / 1000000 }
     elseif ($line -match '^speed=\s*(\S+)') { $us.spd = $Matches[1] }
        }
    } {
 param($tick)
        $frac = if ($total -gt 0) { $us.t / $total } else { -1 }
        $txt = $Spin[$tick % $Spin.Count] + '  ' + (L 'upscaling') + '  ·  ' + (Dur $us.t)
        if ($total -gt 0) { $txt += ' / ' + (Dur $total) }
        if ($us.spd -and $us.spd -ne 'N/A') { $txt += '  ·  ' + $us.spd }
 Draw-Progress $row $frac $txt $tick
    }
    if ($cancel) { Start-Sleep -Milliseconds 300; Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue; return @{ ok = $false; cancelled = $true } }
    if ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $tmpOut)) {
 Move-Item -LiteralPath $tmpOut -Destination $final -Force
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        Draw-Progress $row 1 '' 0 ' '
        return @{ ok = $true; file = $final }
    }
    Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
    return @{ ok = $false; cancelled = $false }
}

function Show-Result($r) {
    $m = ' ' * $St.M; $w = [Console]::WindowWidth
    try { [Console]::SetCursorPosition(0, $r.row) } catch {}
    Wr $Eol
    if ($r.ok) {
 $f = if (@($r.files).Count) { [string]@($r.files)[-1] } else { '' }
 $name = if (@($r.files).Count -gt 1) { "$(@($r.files).Count) ✓" } elseif ($f) { Split-Path $f -Leaf } else { '' }
        Ln ($m + $Col.Ok + '✔  ' + (L 'done') + '   ' + $Col.Fg + (Trunc $name ($w - $St.M - 20)))
 Ln ''
        Ln ($m + $Col.Dim + (L 'done_hint'))
        Flush-Keys
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Spacebar' -and $f -and (Test-Path -LiteralPath $f)) { Start-Process explorer.exe -ArgumentList ('/select,"' + $f + '"') }
    } elseif ($r.cancelled) {
 Ln ($m + $Col.Warn + '■  ' + (L 'cancelled')); Ln ''; Ln ($m + $Col.Dim + (L 'anykey')); Wait-Key
    } else {
        Ln ($m + $Col.Err + '✖  ' + (L 'failed'))
        foreach ($er in @($r.errs | Select-Object -Last 3)) { Ln ($m + '   ' + $Col.Dim + (Trunc ([string]$er) ($w - $St.M - 6))) }
        Ln ''; Ln ($m + $Col.Dim + (L 'anykey')); Wait-Key
    }
}

function Show-Fail([string]$msg, [string]$details) {
    Draw-Header -Compact
    $m = ' ' * $St.M; $w = [Console]::WindowWidth
    Ln ($m + $Col.Err + '✖  ' + $msg)
    foreach ($l in @(($details -split "`n") | Where-Object { $_ } | Select-Object -Last 4)) { Ln ($m + '   ' + $Col.Dim + (Trunc $l ($w - $St.M - 6))) }
    Ln ''; Ln ($m + $Col.Dim + (L 'anykey')); Wait-Key
}

# ---------------------------------------------------------------------
#  Installation des outils (GitHub officiel, sans winget ni admin)
# ---------------------------------------------------------------------
function Get-File([string]$url, [string]$dest, [int]$row) {
    $req = [Net.HttpWebRequest]::Create($url); $req.UserAgent = 'Maelstrom/' + $App.Ver; $req.Timeout = 30000
    $resp = $req.GetResponse(); $total = [double]$resp.ContentLength
    $in = $resp.GetResponseStream(); $fs = [IO.File]::Create($dest)
    $buf = New-Object byte[] 262144; $done = 0.0; $sw = [Diagnostics.Stopwatch]::StartNew(); $last = -1000; $tick = 0
    try {
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
     $fs.Write($buf, 0, $n); $done += $n
     if ($sw.ElapsedMilliseconds - $last -ge 100) {
         $last = $sw.ElapsedMilliseconds; $tick++
         $frac = if ($total -gt 0) { $done / $total } else { -1 }
         $spd = $done / [Math]::Max(0.1, $sw.Elapsed.TotalSeconds)
  $txt = Sz $done; if ($total -gt 0) { $txt += ' / ' + (Sz $total) }; $txt += '  ·  ' + (Sz $spd) + '/s'
  Draw-Progress $row $frac $txt $tick ' '
            }
        }
    } finally { $fs.Close(); $in.Close(); $resp.Close() }
    Draw-Progress $row 1 (Sz $done) 0 ' '
}

function Install-Tools($list) {
    Draw-Header -Compact
    $m = ' ' * $St.M
    Ln ($m + $Col.Acc + '◆ ' + $Col.Hi + (L 'm_tools')); Ln ''
    foreach ($tool in $list) {
        Ln ($m + $Col.Fg + ((L 'getting') -f $tool))
        $row = [Console]::CursorTop; Ln ''; Ln ''; Ln ''
        try {
     New-Item -ItemType Directory -Force -Path $Bin | Out-Null
     if ($tool -eq 'yt-dlp') {
         $dest = Join-Path $Bin 'yt-dlp.exe'
  Get-File $YtUrl "$dest.part" $row
         Move-Item -LiteralPath "$dest.part" -Destination $dest -Force
     } else {
         $zip = Join-Path $Tmp 'ffmpeg.zip'
         Get-File $FfUrl $zip $row
  $z = [IO.Compression.ZipFile]::OpenRead($zip)
  try {
      foreach ($e in $z.Entries) { if ($e.Name -eq 'ffmpeg.exe' -or $e.Name -eq 'ffprobe.exe') { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $Bin $e.Name), $true) } }
  } finally { $z.Dispose() }
         Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
     }
     [Console]::SetCursorPosition(0, $row + 2); Ln ($m + $Col.Ok + '✔  ' + ((L 'installed') -f $tool))
        } catch {
     [Console]::SetCursorPosition(0, $row + 2); Ln ($m + $Col.Err + '✖  ' + ((L 'inst_fail') -f $_.Exception.Message))
        }
        Ln ''
    }
    Refresh-Tools
    Ln ($m + $Col.Dim + (L 'anykey')); Wait-Key
}

function Ensure-Tools {
    Refresh-Tools
    $miss = @(); if (-not $St.YT) { $miss += 'yt-dlp' }; if (-not $St.FF) { $miss += 'ffmpeg' }
    if ($miss.Count -eq 0) { return $true }
    $c = Menu ((L 'need') -f ($miss -join ', ')) @((L 'inst_yes'), (L 'inst_no'))
    if ($c -ne 0) { return $false }
    Install-Tools $miss
    return [bool]($St.YT -and $St.FF)
}

function Update-Yt {
    if (-not $St.YT) { Install-Tools @('yt-dlp'); return }
    Draw-Header -Compact
    $m = ' ' * $St.M
    Ln ($m + $Col.Acc + '◆ ' + $Col.Hi + (L 't_up')); Ln ''
    & $St.YT -U 2>&1 | ForEach-Object { Ln ($m + $Col.Dim + "$_") }
    Ln ''; Ln ($m + $Col.Dim + (L 'anykey')); Wait-Key
}

# ---------------------------------------------------------------------
#  Notice : QR code dans le terminal
# ---------------------------------------------------------------------
function Show-Notice {
    if (-not ('MsQr' -as [type])) { Start-Process $App.Notice; return }
    Draw-Header -Compact
    $qr = [MsQr]::Encode($App.Notice); $n = $qr.GetLength(0); $q = 4
    $w = [Console]::WindowWidth; $qw = $n + 2 * $q
    $pad = ' ' * [Math]::Max(2, [int](($w - $qw) / 2))
    $title = L 'notice'
    Ln ((' ' * [Math]::Max(2, [int](($w - $title.Length - 2) / 2))) + $Col.Acc + '◆ ' + $Col.Hi + $title)
    Ln ''
    $ink = $Esc + '[38;2;0;0;0m' + $Esc + '[48;2;255;255;255m'
    for ($y = -$q; $y -lt $n + $q; $y += 2) {
        $sb = New-Object Text.StringBuilder
        for ($x = -$q; $x -lt $n + $q; $x++) {
     $t1 = ($y -ge 0 -and $y -lt $n -and $x -ge 0 -and $x -lt $n -and $qr[$y, $x])
     $y2 = $y + 1
            $t2 = ($y2 -ge 0 -and $y2 -lt $n -and $x -ge 0 -and $x -lt $n -and $qr[$y2, $x])
     if ($t1 -and $t2) { [void]$sb.Append('█') } elseif ($t1) { [void]$sb.Append('▀') } elseif ($t2) { [void]$sb.Append('▄') } else { [void]$sb.Append(' ') }
        }
 Ln ($pad + $ink + $sb.ToString())
    }
    Ln ''
    $s1 = L 'scan'; $s2 = $App.Notice; $s3 = L 'notice_hint'
    Ln ((' ' * [Math]::Max(2, [int](($w - $s1.Length) / 2))) + $Col.Fg + $s1)
    Ln ((' ' * [Math]::Max(2, [int](($w - $s2.Length) / 2))) + $Col.Acc + $s2)
    Ln ''
    Ln ((' ' * [Math]::Max(2, [int](($w - $s3.Length) / 2))) + $Col.Dim + $s3)
    Flush-Keys
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') { Start-Process $App.Notice }
        elseif ($k.Key -eq 'Escape' -or $k.Key -eq 'Backspace') { return }
    }
}

# ---------------------------------------------------------------------
#  Parcours : lien unique
# ---------------------------------------------------------------------
function Flow-Single {
    if (-not (Ensure-Tools)) { return }
    Draw-Header -Compact
    $m = ' ' * $St.M
    Ln ($m + $Col.Acc + '◆ ' + $Col.Hi + (L 'm_dl'))
    Ln ($m + '  ' + $Col.Dim + (L 'paste'))
    Ln ''
    Wr ($m + $Col.Acc + '› ' + $Col.Fg)
    $url = Read-Url
    Wr $Rst
    if (-not $url) { return }
    Ln ''
    $info = Get-Info $url ([Console]::CursorTop)
    if ($info -is [string]) { return }
    if ($null -eq $info) { Show-Fail (L 'analyze_fail') $St.LastErr; return }

    $title = [string](First (G $info 'title') $url)
    $isPl = (G $info '_type') -eq 'playlist'
    $sub = Trunc $title 70
    $type = Menu (L 'choose_type') @(('▶  ' + (L 't_video')), ('♪  ' + (L 't_audio'))) 0 $sub
    if ($type -lt 0) { return }

    $up = $false
    if ($type -eq 0) {
        $hs = if ($isPl) { @() } else { @(Heights $info) }
        $labels = @(); $vals = @()
 $maxTxt = if ($hs.Count) { $Col.Dim + '   ' + (HL $hs[0]) } else { '' }
        $labels += '★  ' + (L 'q_max') + $maxTxt; $vals += 0
        $list = if ($isPl) { @(2160, 1440, 1080, 720, 480) } else { $hs }
 foreach ($h in $list) { $labels += '   ' + (HL $h); $vals += [int]$h }
        $canUp = [bool]($St.FF -and $hs.Count -and $hs[0] -lt 2160)
        if ($canUp) { $labels += '⇡  ' + (L 'q_up'); $vals += -1 }
 $q = Menu (L 'choose_q') $labels 0 $sub
 if ($q -lt 0) { return }
 $hsel = $vals[$q]
        if ($hsel -eq -1) { $up = $true; $hsel = 0 }
        $xargs = Video-Args $hsel
        $fmt = (L 't_video') + ' MP4  ·  '
        if ($hsel -gt 0) { $fmt += (HL $hsel) } elseif ($hs.Count) { $fmt += (L 'q_max') + ' (' + (HL $hs[0]) + ')' } else { $fmt += (L 'q_max') }
 if ($up) { $fmt += '  →  4K upscale' }
    } else {
        $src = Audio-Source $info
        $ak = @('best', 'mp3', 'wav', 'flac', 'm4a')
        $labels = @($ak | ForEach-Object { L "a_$_" })
        $hint = if ($src) { (L 'source') + ' : ' + $src } else { $sub }
        $q = Menu (L 'choose_a') $labels ([Array]::IndexOf($ak, [string]$Cfg.af)) $hint
 if ($q -lt 0) { return }
        $xargs = Audio-Args $ak[$q]
 $fmt = (L 't_audio') + '  ·  ' + (AfLabel $ak[$q])
    }

    $r = Do-Download $url $info $xargs $fmt ''
    if ($r.ok -and $up -and @($r.files).Count) {
 $u = Do-Upscale ([string]@($r.files)[-1]) (G $info 'duration') ($r.row - 2)
 if ($u.ok) { $r.files = @($u.file) } elseif ($u.cancelled) { $r.ok = $false; $r.cancelled = $true }
    }
    Show-Result $r
}

# ---------------------------------------------------------------------
#  Parcours : file d'attente
# ---------------------------------------------------------------------
function Flow-Queue {
    if (-not (Ensure-Tools)) { return }
    Draw-Header -Compact
    $m = ' ' * $St.M
    Ln ($m + $Col.Acc + '◆ ' + $Col.Hi + (L 'q_title'))
    Ln ($m + '  ' + $Col.Dim + (L 'q_paste'))
    Ln ''
    $urls = @()
    while ($true) {
        Wr ($m + $Col.Dim + ('{0,3}' -f ($urls.Count + 1)) + ' ' + $Col.Acc + '› ' + $Col.Fg)
        $u = Read-Url
 Wr $Rst
        if (-not $u) { break }
 $urls += $u
    }
    if ($urls.Count -eq 0) { return }
    $head = (L 'q_count') -f $urls.Count
    $type = Menu (L 'choose_type') @(('▶  ' + (L 't_video')), ('♪  ' + (L 't_audio'))) 0 $head
    if ($type -lt 0) { return }
    if ($type -eq 0) {
        $vk = @('max', '2160', '1440', '1080', '720', '480')
        $q = Menu (L 'choose_q') @($vk | ForEach-Object { VqLabel $_ }) ([Array]::IndexOf($vk, [string]$Cfg.vq)) $head
        if ($q -lt 0) { return }
        $h = if ($vk[$q] -eq 'max') { 0 } else { [int]$vk[$q] }
        $xargs = Video-Args $h
        $fmt = (L 't_video') + ' MP4  ·  ' + (VqLabel $vk[$q])
    } else {
        $ak = @('best', 'mp3', 'wav', 'flac', 'm4a')
 $q = Menu (L 'choose_a') @($ak | ForEach-Object { L "a_$_" }) ([Array]::IndexOf($ak, [string]$Cfg.af)) $head
        if ($q -lt 0) { return }
 $xargs = Audio-Args $ak[$q]
        $fmt = (L 't_audio') + '  ·  ' + (AfLabel $ak[$q])
    }

    $ok = 0; $ko = 0; $n = $urls.Count
    for ($i = 0; $i -lt $n; $i++) {
        $badge = (L 'item') + ' ' + ($i + 1) + '/' + $n
        Draw-Header -Compact
        Ln ($m + $Col.Acc + '◆ ' + $Col.Hi + (L 'q_title') + $Col.Dim + '   ·   ' + $badge)
 Ln ''
 $info = Get-Info $urls[$i] ([Console]::CursorTop)
        if ($info -is [string]) { break }
        if ($null -eq $info) { $ko++; continue }
        $r = Do-Download $urls[$i] $info $xargs $fmt $badge
        if ($r.cancelled) { break }
        if ($r.ok) { $ok++ } else { $ko++ }
    }
    Draw-Header -Compact
    Ln ($m + $Col.Acc + '◆ ' + $Col.Hi + (L 'q_title'))
    Ln ''
    $sumCol = if ($ko -eq 0) { $Col.Ok } else { $Col.Warn }
    Ln ($m + $sumCol + '✔  ' + ((L 'q_sum') -f $ok, $ko))
    Ln ''
    Ln ($m + $Col.Dim + (L 'anykey')); Wait-Key
}

# ---------------------------------------------------------------------
#  Serveur local : accès depuis le téléphone (même Wi-Fi)
#  TcpListener brut : aucun droit admin ni réservation d'URL nécessaire.
# ---------------------------------------------------------------------
$Web = @{ sx = 0; sy = 0; sw = 40 }

# Page mobile v6.1 — style chaleureux (espresso, or, corail), art ASCII décoratif
$WebHtml = @'
<!doctype html>
<html lang="{{LANG}}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#140E0B">
<meta name="referrer" content="no-referrer">
<link rel="icon" href="data:,">
<title>Maelström</title>
<style>
:root{--bg:#140E0B;--bd:rgba(255,214,176,.10);--bd2:rgba(255,214,176,.18);--hi:#FBF1E4;--fg:#E9DACA;--dim:#A8917F;--mute:#7A6456;--gold:#FFCE80;--amber:#F4A867;--coral:#E8806A;--rose:#D9708C;--sage:#9CCB8E;--err:#F07A6A;
--grad:linear-gradient(100deg,#FFCE80 0%,#F4A867 35%,#E8806A 70%,#D9708C 100%);
--sans:"Inter","SF Pro Text",-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
--serif:"Iowan Old Style","Palatino Linotype",Palatino,"Book Antiqua",Georgia,serif;
--mono:ui-monospace,"SF Mono","Cascadia Mono",Menlo,Consolas,"Roboto Mono",monospace}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
[hidden]{display:none!important}
html,body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--sans);-webkit-font-smoothing:antialiased;-webkit-text-size-adjust:100%}
body{min-height:100vh;overflow-x:hidden;background:radial-gradient(900px 520px at 12% -12%,rgba(244,168,103,.17),transparent 65%),radial-gradient(760px 520px at 105% 8%,rgba(217,112,140,.11),transparent 60%),radial-gradient(900px 600px at 50% 118%,rgba(232,128,106,.10),transparent 60%),var(--bg)}
body::before{content:"";position:fixed;inset:0;pointer-events:none;opacity:.08;mix-blend-mode:overlay;background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E")}
.wrap{position:relative;max-width:640px;margin:0 auto;padding:max(26px,env(safe-area-inset-top)) 18px max(36px,env(safe-area-inset-bottom))}
.hero{position:relative;text-align:center;padding:22px 0 4px;isolation:isolate}
.swirl{position:absolute;left:50%;top:46%;margin:0;z-index:0;font-family:var(--mono);font-size:12px;line-height:1;white-space:pre;pointer-events:none;user-select:none;opacity:.26;background:var(--grad);-webkit-background-clip:text;background-clip:text;color:transparent;transform:translate(-50%,-50%);animation:spin 120s linear infinite;-webkit-mask:radial-gradient(closest-side,#000 35%,transparent);mask:radial-gradient(closest-side,#000 35%,transparent)}
@keyframes spin{to{transform:translate(-50%,-50%) rotate(360deg)}}
.logo{position:relative;z-index:1;display:inline-block;margin:0;text-align:left;font-family:var(--mono);font-size:min(12px,calc((100vw - 36px) / 49));line-height:1.04;white-space:pre;font-variant-ligatures:none;user-select:none;filter:drop-shadow(0 8px 26px rgba(244,168,103,.25))}
.logo i{font-style:normal;color:#6E4537}
.tag{position:relative;z-index:1;margin:16px 0 0;font-family:var(--serif);font-style:italic;font-size:17px;color:var(--fg)}
.tag b{font-family:var(--mono);font-style:normal;font-weight:400;font-size:11px;color:var(--amber);opacity:.85;margin:0 .7em;vertical-align:2px}
.pill{position:relative;z-index:1;display:inline-flex;align-items:center;gap:9px;margin-top:16px;padding:7px 15px;border-radius:999px;background:rgba(255,236,214,.05);border:1px solid var(--bd);font-size:12.5px;color:var(--dim);backdrop-filter:blur(6px)}
.pill .dot{width:7px;height:7px;border-radius:50%;background:var(--sage);animation:pulse 2.2s ease-out infinite}
.pill.off .dot{background:var(--err);animation:none}
@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(156,203,142,.55)}100%{box-shadow:0 0 0 9px rgba(156,203,142,0)}}
.card{position:relative;margin-top:24px;padding:22px 18px 20px;border-radius:26px;background:linear-gradient(180deg,rgba(255,236,214,.065),rgba(255,236,214,.025));border:1px solid var(--bd);box-shadow:inset 0 1px 0 rgba(255,240,220,.07),0 30px 60px -32px rgba(0,0,0,.7)}
.hd{display:flex;align-items:baseline;gap:10px}
.ix{font-family:var(--mono);font-size:11px;color:var(--amber);opacity:.85}
h2{margin:0;font-family:var(--serif);font-weight:500;font-size:23px;color:var(--hi);letter-spacing:.01em}
.lead{margin:8px 0 0;font-size:13.5px;line-height:1.55;color:var(--dim)}
.field{display:flex;align-items:center;gap:10px;margin-top:18px;padding:3px 6px 3px 16px;border-radius:18px;background:rgba(10,6,4,.45);border:1px solid var(--bd2);transition:border-color .25s,box-shadow .25s}
.field:focus-within{border-color:var(--amber);box-shadow:0 0 0 4px rgba(244,168,103,.12)}
.pr{font-family:var(--mono);color:var(--amber)}
input{flex:1;min-width:0;background:transparent;border:0;outline:0;color:var(--hi);font:inherit;font-size:16px;padding:14px 0}
input::placeholder{color:var(--mute)}
.ghost{font:inherit;font-size:13px;color:var(--dim);background:transparent;border:1px solid var(--bd2);border-radius:14px;padding:10px 14px;cursor:pointer;transition:all .2s}
.ghost:active{background:rgba(255,236,214,.06)}
.field .ghost{border:0;padding:8px 10px}
.seg{position:relative;display:grid;grid-template-columns:1fr 1fr;margin-top:16px;padding:4px;border-radius:18px;background:rgba(8,5,3,.45);border:1px solid var(--bd)}
.seg-i{position:absolute;top:4px;bottom:4px;left:4px;width:calc(50% - 4px);border-radius:14px;background:var(--grad);box-shadow:0 8px 22px -10px rgba(232,128,106,.8);transition:transform .45s cubic-bezier(.2,.9,.2,1)}
.seg[data-k="audio"] .seg-i{transform:translateX(100%)}
.seg button{position:relative;z-index:1;font:inherit;font-size:14.5px;font-weight:600;padding:12px 8px;border:0;background:transparent;color:var(--dim);cursor:pointer;transition:color .3s}
.seg button[aria-pressed="true"]{color:#2B150D}
.lbl{margin:20px 2px 10px;font-size:11px;letter-spacing:.2em;text-transform:uppercase;color:var(--dim)}
.chips{display:flex;flex-wrap:wrap;gap:8px}
.chip{display:inline-flex;align-items:baseline;gap:7px;font:inherit;font-size:13.5px;font-weight:500;color:var(--fg);background:rgba(255,236,214,.04);border:1px solid var(--bd2);border-radius:999px;padding:9px 15px;cursor:pointer;transition:all .2s}
.chip small{font-size:10.5px;color:var(--dim)}
.chip[aria-pressed="true"]{color:var(--hi);border-color:var(--amber);background:rgba(244,168,103,.15);box-shadow:0 0 0 3px rgba(244,168,103,.08)}
.chip[aria-pressed="true"] small{color:var(--gold)}
.note{margin:12px 2px 0;font-size:12px;line-height:1.55;color:var(--dim)}
.note:empty{display:none}
.go{display:flex;align-items:center;justify-content:center;gap:12px;width:100%;margin-top:22px;padding:16px;border:0;border-radius:18px;background:var(--grad);background-size:160% 100%;color:#2B150D;font:inherit;font-size:15.5px;font-weight:700;letter-spacing:.03em;cursor:pointer;box-shadow:0 14px 34px -14px rgba(232,128,106,.8),inset 0 1px 0 rgba(255,255,255,.35);transition:transform .15s,background-position .6s,opacity .2s}
.go:active{transform:scale(.985)}
.go:hover{background-position:100% 0}
.go-a{font-family:var(--mono);display:inline-block}
.go.busy{opacity:.7;pointer-events:none}
.go.busy .go-a{animation:bob .8s ease-in-out infinite}
@keyframes bob{50%{transform:translateY(3px)}}
.msg{min-height:1.3em;margin:12px 2px 0;font-size:13px;line-height:1.45;color:var(--err)}
.wave{margin:30px 0 0;font-family:var(--mono);font-size:13px;letter-spacing:3px;white-space:nowrap;overflow:hidden;text-align:center;background:var(--grad);background-size:200% 100%;-webkit-background-clip:text;background-clip:text;color:transparent;opacity:.5;animation:flow 7s linear infinite;user-select:none}
@keyframes flow{to{background-position:200% 0}}
.sec{display:flex;align-items:baseline;gap:10px;margin:22px 4px 14px}
.count{margin-left:auto;font-family:var(--mono);font-size:12px;color:var(--dim)}
.job{display:grid;grid-template-columns:84px 1fr;gap:12px 14px;margin-top:0;padding:14px;border-radius:24px;animation:rise .5s cubic-bezier(.2,.9,.2,1)}
.job+.job{margin-top:12px}
@keyframes rise{from{opacity:0;transform:translateY(10px)}}
.th{position:relative;width:84px;height:84px;border-radius:16px;background:#2A1C16 center/cover no-repeat;overflow:hidden;box-shadow:inset 0 0 0 1px rgba(255,220,190,.08)}
.th::after{content:attr(data-i);position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:24px;color:var(--amber);opacity:.6}
.bd{min-width:0}
.ti{font-weight:600;font-size:14.5px;line-height:1.35;color:var(--hi);overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;word-break:break-word}
.meta{display:flex;flex-wrap:wrap;align-items:center;gap:6px 8px;margin-top:7px;font-size:11.5px;color:var(--dim)}
.badge{padding:3px 9px;border-radius:999px;border:1px solid var(--bd2);font-size:10px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--dim)}
.badge.run{color:var(--gold);border-color:rgba(255,206,128,.35);background:rgba(255,206,128,.08)}
.badge.ok{color:var(--sage);border-color:rgba(156,203,142,.35);background:rgba(156,203,142,.08)}
.badge.err{color:var(--err);border-color:rgba(240,122,106,.35);background:rgba(240,122,106,.08)}
.prog{position:relative;height:6px;margin-top:12px;border-radius:99px;background:rgba(255,236,214,.08);overflow:hidden}
.prog>i{position:absolute;left:0;top:0;bottom:0;width:0;border-radius:99px;background:var(--grad);transition:width .6s cubic-bezier(.2,.9,.2,1)}
.prog>i::after{content:"";position:absolute;inset:0;background:linear-gradient(90deg,transparent,rgba(255,255,255,.4),transparent);animation:sh 1.8s ease-in-out infinite}
.prog.full>i::after{display:none}
.prog.ind>i{width:38%!important;transition:none;animation:ind 1.4s ease-in-out infinite}
@keyframes sh{0%{transform:translateX(-100%)}100%{transform:translateX(100%)}}
@keyframes ind{0%{left:-38%}100%{left:100%}}
.info{margin-top:8px;font-family:var(--mono);font-size:11.5px;line-height:1.5;color:var(--dim);word-break:break-word}
.info:empty{display:none}
.acts{grid-column:1/-1;display:flex;flex-wrap:wrap;gap:8px}
.acts:empty{display:none}
.save{flex:1 1 200px;display:inline-flex;align-items:center;justify-content:center;gap:9px;padding:12px 16px;border-radius:16px;background:var(--grad);color:#2B150D;font-weight:700;font-size:14px;text-decoration:none;box-shadow:0 10px 26px -12px rgba(232,128,106,.8)}
.save span{font-family:var(--mono)}
.empty{padding:34px 16px;text-align:center;font-size:14px;line-height:1.6;color:var(--dim);border:1px dashed var(--bd2);border-radius:24px}
.orn{display:block;font-family:var(--mono);color:var(--amber);opacity:.6;letter-spacing:.35em;margin-bottom:8px}
footer{margin-top:42px;text-align:center;font-size:12px;line-height:1.9;color:var(--mute)}
.toast{position:fixed;left:50%;bottom:max(22px,env(safe-area-inset-bottom));z-index:9;transform:translate(-50%,30px);opacity:0;padding:11px 18px;border-radius:999px;background:rgba(40,27,21,.94);border:1px solid var(--bd2);color:var(--hi);font-size:13.5px;white-space:nowrap;box-shadow:0 18px 40px -16px rgba(0,0,0,.8);transition:all .35s cubic-bezier(.2,.9,.2,1);pointer-events:none}
.toast.on{opacity:1;transform:translate(-50%,0)}
.lock{position:fixed;inset:0;z-index:10;display:none;align-items:center;justify-content:center;padding:30px;text-align:center;font-size:15px;line-height:1.7;color:var(--fg);background:rgba(20,14,11,.97)}
.lock.on{display:flex}
.lock pre{margin:0 0 16px;font-family:var(--mono);font-size:14px;line-height:1.1;color:var(--amber)}
@media (max-width:520px){.wrap{padding-left:14px;padding-right:14px}.card{padding:18px 15px;border-radius:24px}.job{grid-template-columns:68px 1fr;padding:12px}.th{width:68px;height:68px;border-radius:14px}h2{font-size:21px}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
</style>
</head>
<body>
<div class="wrap">
<header class="hero">
<pre class="swirl" id="swirl" aria-hidden="true"></pre>
<pre class="logo" aria-label="Maelström">{{LOGO}}</pre>
<p class="tag"><b>✦</b>{{TAG}}<b>✦</b></p>
<div class="pill" id="st"><i class="dot"></i><span>…</span></div>
</header>

<form id="f" class="card" autocomplete="off" novalidate>
<div class="hd"><span class="ix">01</span><h2 data-t="newdl"></h2></div>
<p class="lead" data-t="lead"></p>
<label class="field"><span class="pr">❯</span><input id="u" type="text" inputmode="url" enterkeyhint="go" spellcheck="false" autocapitalize="off" autocorrect="off"><button type="button" id="clr" class="ghost" hidden>✕</button></label>
<div class="seg" id="kind"><span class="seg-i"></span><button type="button" data-v="video">▶&nbsp; <span data-t="video"></span></button><button type="button" data-v="audio">♪&nbsp; <span data-t="audio"></span></button></div>
<div class="lbl" id="fmtl"></div>
<div class="chips" id="fmts"></div>
<p class="note" id="note"></p>
<button class="go" id="go" type="submit"><span data-t="go"></span><span class="go-a">↓</span></button>
<p class="msg" id="msg"></p>
</form>

<div class="wave" aria-hidden="true">~ · ~ · ~ · ~ · ~ · ~ · ~ · ~ · ~ · ~ · ~ · ~ · ~ · ~ · ~ · ~ · ~ · ~ · ~ · ~ · ~ · ~</div>

<div class="sec"><span class="ix">02</span><h2 data-t="queue"></h2><span class="count" id="count"></span></div>
<div id="jobs"></div>
<div class="empty" id="empty"><span class="orn">· ˚ ✦ ˚ ·</span><span data-t="empty"></span></div>

<footer><span class="orn">· ˚ ✦ ˚ ·</span>MAELSTRÖM · v{{VER}}<br><span id="pc"></span></footer>
</div>
<div class="lock" id="lock"><div><pre>╭─────╮
│  ◉  │
╰─────╯</pre><span data-t="lock"></span></div></div>
<div class="toast" id="toast"></div>

<script>
(function(){
"use strict";
var LANG="{{LANG}}";
var T={
fr:{newdl:"Nouveau téléchargement",lead:"Collez un lien : le PC le télécharge puis l'envoie directement sur ce téléphone. Le fichier est ensuite effacé du PC.",paste:"Collez un lien ou le texte de partage…",video:"Vidéo",audio:"Audio",quality:"Qualité",format:"Format",max:"Max",orig:"Original",rec:"conseillé",go:"Télécharger",queue:"Vos fichiers",empty:"Rien pour l'instant. Collez un lien pour commencer.",queued:"En attente…",start:"Préparation…",fin:"Finalisation (fusion / conversion)…",b_wait:"En attente",b_run:"En cours",b_ready:"Prêt",b_sent:"Envoyé",b_err:"Échec",b_cancel:"Annulé",save:"Enregistrer sur le téléphone",again:"Renvoyer sur le téléphone",cancel:"Annuler",remove:"Retirer",sending:"Envoi vers le téléphone…",sentinfo:"Envoyé ✓ · effacé du PC dans quelques minutes",goneinfo:"Envoyé ✓ · fichier effacé du PC",stream:"flux",online:"Connecté",offline:"PC injoignable · nouvelle tentative…",badurl:"Aucun lien trouvé dans ce texte.",neterr:"Le PC ne répond pas. Laissez Maelström ouvert sur l'écran « Accès téléphone ».",added:"Ajouté ✓",lock:"Accès refusé. Sur le PC : Paramètres → Ouvrir le port, puis scannez le QR code.",maxnote:"4K et Max peuvent être en VP9 ou AV1, que certains téléphones lisent mal. 1080p reste en H.264, lisible partout.",u:["o","Ko","Mo","Go"]},
en:{newdl:"New download",lead:"Paste a link: the PC downloads it, then sends it straight to this phone. The file is then deleted from the PC.",paste:"Paste a link or share text…",video:"Video",audio:"Audio",quality:"Quality",format:"Format",max:"Max",orig:"Original",rec:"recommended",go:"Download",queue:"Your files",empty:"Nothing yet. Paste a link to start.",queued:"Waiting…",start:"Preparing…",fin:"Finalizing (merge / conversion)…",b_wait:"Waiting",b_run:"Downloading",b_ready:"Ready",b_sent:"Sent",b_err:"Failed",b_cancel:"Cancelled",save:"Save to phone",again:"Send to phone again",cancel:"Cancel",remove:"Remove",sending:"Sending to phone…",sentinfo:"Sent ✓ · deleted from the PC in a few minutes",goneinfo:"Sent ✓ · file deleted from the PC",stream:"stream",online:"Connected",offline:"PC unreachable · retrying…",badurl:"No link found in this text.",neterr:"The PC is not responding. Keep Maelström open on the “Phone access” screen.",added:"Added ✓",lock:"Access denied. On the PC: Settings → Open the port, then scan the QR code.",maxnote:"4K and Max may be VP9 or AV1, which some phones play poorly. 1080p stays H.264 and plays everywhere.",u:["B","KB","MB","GB"]}
};
var t=T[LANG]||T.en;
function $(s){return document.querySelector(s);}
var K="";
try{var qs=new URLSearchParams(location.search);K=qs.get("k")||"";if(K){localStorage.setItem("ms_k",K);history.replaceState(null,"","/");}else{K=localStorage.getItem("ms_k")||"";}}catch(e){}
var kind="video",fmt={video:"1080",audio:"mp3"};
try{var pv=JSON.parse(localStorage.getItem("ms_pref")||"{}");if(pv.kind==="audio"||pv.kind==="video")kind=pv.kind;if(pv.fmt&&pv.fmt.video&&pv.fmt.audio)fmt=pv.fmt;}catch(e){}
var OPTS={video:[["1080","1080p",t.rec],["720","720p",""],["2160","4K",""],["max",t.max,""]],audio:[["mp3","MP3","320 kb/s"],["m4a","M4A","AAC"],["best",t.orig,""]]};
var SP="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏",tick=0,last=[],els={},timer=null,locked=false,fails=0,auto={};
try{auto=JSON.parse(localStorage.getItem("ms_auto")||"{}")||{};}catch(e){auto={};}
function esc(s){return String(s==null?"":s).replace(/[&<>"']/g,function(c){return{"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c];});}
function sz(b){if(!(b>=0))return"?";var i=0;while(b>=1024&&i<3){b/=1024;i++;}return b.toFixed(i>=2?1:0)+" "+t.u[i];}
function pad(n){return(n<10?"0":"")+n;}
function dur(s){s=Math.max(0,Math.round(s));var h=Math.floor(s/3600),m=Math.floor(s%3600/60),x=s%60;return(h?h+":"+pad(m):m)+":"+pad(x);}
function label(j){if(j.kind==="audio")return j.fmt==="mp3"?"MP3 320":(j.fmt==="m4a"?"M4A":t.orig);return j.fmt==="max"?t.max:(j.fmt==="2160"?"4K":j.fmt+"p");}
function fileUrl(j){return"/f/"+j.id+"?k="+encodeURIComponent(K);}
function btn(id,txt){return"<button type=\"button\" class=\"ghost\" data-c=\""+id+"\">"+esc(txt)+"</button>";}
function saveA(j,txt){return"<a class=\"save\" href=\""+fileUrl(j)+"\" download data-s=\""+j.id+"\"><span>↓</span>"+esc(txt)+"</a>";}
function msg(s){$("#msg").textContent=s||"";}
function toast(s){var e=$("#toast");e.textContent=s;e.classList.add("on");clearTimeout(e._t);e._t=setTimeout(function(){e.classList.remove("on");},2600);}
function lock(){locked=true;clearTimeout(timer);$("#lock").classList.add("on");}
function keepAuto(){try{var k=Object.keys(auto);if(k.length>60){var n={};k.slice(-30).forEach(function(x){n[x]=1;});auto=n;}localStorage.setItem("ms_auto",JSON.stringify(auto));}catch(e){}}
function pull(j){var a=document.createElement("a");a.href=fileUrl(j);a.setAttribute("download","");document.body.appendChild(a);a.click();setTimeout(function(){a.remove();},1500);toast(t.sending);}
function req(path,opt,ms){opt=opt||{};var ctl=window.AbortController?new AbortController():null,tm=null;if(ctl){opt.signal=ctl.signal;tm=setTimeout(function(){ctl.abort();},ms||7000);}
 return fetch(path+(path.indexOf("?")<0?"?":"&")+"k="+encodeURIComponent(K),opt).then(function(r){clearTimeout(tm);if(r.status===403){lock();throw new Error("key");}return r;},function(e){clearTimeout(tm);throw e;});}

function renderOpts(){
 $("#kind").setAttribute("data-k",kind);
 var bs=document.querySelectorAll("#kind button");
 for(var i=0;i<bs.length;i++)bs[i].setAttribute("aria-pressed",String(bs[i].getAttribute("data-v")===kind));
 $("#fmtl").textContent=kind==="video"?t.quality:t.format;
 $("#fmts").innerHTML=OPTS[kind].map(function(o){return"<button type=\"button\" class=\"chip\" data-v=\""+o[0]+"\" aria-pressed=\""+(fmt[kind]===o[0])+"\">"+esc(o[1])+(o[2]?"<small>"+esc(o[2])+"</small>":"")+"</button>";}).join("");
 $("#note").textContent=(kind==="video"&&(fmt.video==="max"||fmt.video==="2160"))?t.maxnote:"";
 try{localStorage.setItem("ms_pref",JSON.stringify({kind:kind,fmt:fmt}));}catch(e){}
}
$("#kind").addEventListener("click",function(e){var b=e.target.closest("button");if(b){kind=b.getAttribute("data-v");renderOpts();}});
$("#fmts").addEventListener("click",function(e){var b=e.target.closest(".chip");if(b){fmt[kind]=b.getAttribute("data-v");renderOpts();}});
$("#u").addEventListener("input",function(){$("#clr").hidden=!this.value;msg("");});
$("#clr").addEventListener("click",function(){$("#u").value="";this.hidden=true;$("#u").focus();});
$("#f").addEventListener("submit",function(e){
 e.preventDefault();
 var m=$("#u").value.match(/https?:\/\/[^\s<>"']+/i);
 if(!m){msg(t.badurl);return;}
 var go=$("#go");go.disabled=true;go.classList.add("busy");msg("");
 req("/api/add",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({url:m[0],kind:kind,fmt:fmt[kind]})},12000)
 .then(function(r){if(r.ok)return r.json();return r.json().catch(function(){return{};}).then(function(d){throw new Error(d&&d.error==="url"?"url":"http");});})
 .then(function(){$("#u").value="";$("#clr").hidden=true;$("#u").blur();toast(t.added);poll();})
 .catch(function(x){if(x&&x.message==="key")return;msg(x&&x.message==="url"?t.badurl:t.neterr);})
 .then(function(){go.disabled=false;go.classList.remove("busy");});
});
$("#jobs").addEventListener("click",function(e){
 var s=e.target.closest("[data-s]");if(s){auto[s.getAttribute("data-s")]=1;keepAuto();toast(t.sending);return;}
 var b=e.target.closest("[data-c]");if(!b)return;b.disabled=true;
 req("/api/cancel?id="+b.getAttribute("data-c"),{method:"POST"}).then(function(){poll();}).catch(function(){b.disabled=false;});
});

function setH(el,sel,html){if(el._c[sel]!==html){el._c[sel]=html;el.querySelector(sel).innerHTML=html;}}
function render(list){
 var box=$("#jobs"),seen={},spin=SP.charAt(tick%SP.length);
 $("#empty").style.display=list.length?"none":"";
 $("#count").textContent=list.length?String(list.length):"";
 list.forEach(function(j,i){
  seen[j.id]=1;var el=els[j.id];
  if(!el){el=document.createElement("article");el.className="card job";el._c={};el.innerHTML="<div class=\"th\"></div><div class=\"bd\"><div class=\"ti\"></div><div class=\"meta\"></div><div class=\"prog\"><i></i></div><div class=\"info\"></div></div><div class=\"acts\"></div>";els[j.id]=el;}
  if(box.children[i]!==el)box.insertBefore(el,box.children[i]||null);
  var th=el.querySelector(".th");
  if(j.thumb){if(th.getAttribute("data-u")!==j.thumb){th.setAttribute("data-u",j.thumb);th.style.backgroundImage="url(\""+j.thumb.replace(/"/g,"%22")+"\")";th.setAttribute("data-i","");}}
  else th.setAttribute("data-i",j.kind==="audio"?"♪":"▶");
  var s=j.state,badge="",bc="",info="",acts="",pct=-2,site=(j.site&&j.site!=="NA")?j.site:"";
  if(s==="run"){
   var f=(j.tot>0&&j.dl>=0)?j.dl/j.tot:-1;badge=t.b_run;bc="run";acts=btn(j.id,t.cancel);
   if(f<0||f>=0.999){pct=-1;info=spin+"  "+(f>=0.999?t.fin:t.start);}
   else{pct=f*100;var p=[(pct.toFixed(1))+" %",sz(j.dl)+(j.tot>0?" / "+sz(j.tot):"")];if(j.spd>0)p.push(sz(j.spd)+"/s");if(j.eta>=0)p.push(dur(j.eta));if(j.stage>1)p.push(t.stream+" "+j.stage);info=spin+"  "+p.join("  ·  ");}
  }else if(s==="queued"){badge=t.b_wait;info=spin+"  "+t.queued;acts=btn(j.id,t.cancel);}
  else if(s==="done"||s==="sent"){
   badge=s==="done"?t.b_ready:t.b_sent;bc="ok";pct=100;
   info=j.sending?spin+"  "+t.sending:(s==="sent"?t.sentinfo:(j.name+(j.size>=0?"  ·  "+sz(j.size):"")));
   acts=saveA(j,s==="done"?t.save:t.again)+btn(j.id,t.remove);
   if(s==="done"&&!auto[j.id]&&!document.hidden){auto[j.id]=1;keepAuto();setTimeout(function(){pull(j);},400);}
  }else if(s==="gone"){badge=t.b_sent;bc="ok";info=t.goneinfo;acts=btn(j.id,t.remove);}
  else if(s==="error"){badge=t.b_err;bc="err";info=j.err||"";acts=btn(j.id,t.remove);}
  else{badge=t.b_cancel;acts=btn(j.id,t.remove);}
  setH(el,".ti",esc(j.title||j.url));
  setH(el,".meta","<span class=\"badge "+bc+"\">"+esc(badge)+"</span><span>"+esc((site?site+" · ":"")+(j.kind==="audio"?t.audio:t.video)+" "+label(j))+"</span>");
  setH(el,".info",esc(info));
  setH(el,".acts",acts);
  var pr=el.querySelector(".prog");
  if(pct===-2){pr.hidden=true;}else{pr.hidden=false;pr.classList.toggle("ind",pct===-1);pr.classList.toggle("full",pct>=100);pr.firstChild.style.width=(pct<0?38:pct)+"%";}
 });
 for(var id in els){if(!seen[id]){els[id].remove();delete els[id];}}
}
function setSt(on,pc){var s=$("#st");s.className="pill"+(on?"":" off");s.querySelector("span").textContent=on?t.online+(pc?" · "+pc:""):t.offline;if(pc)$("#pc").textContent=pc;}
function poll(){
 clearTimeout(timer);if(locked)return;
 req("/api/jobs",{cache:"no-store"},6000).then(function(r){return r.json();}).then(function(d){
  fails=0;setSt(true,d.pc);last=d.jobs||[];render(last);
  var busy=last.some(function(j){return j.state==="run"||j.state==="queued"||j.sending;});
  timer=setTimeout(poll,busy?800:1800);
 }).catch(function(){if(locked)return;fails++;if(fails>=2)setSt(false);timer=setTimeout(poll,fails>3?3000:1200);});
}
function swirl(){
 var W=48,H=24,g=[],x,y,i,C="·.:~*+✦";
 for(y=0;y<H;y++){g.push([]);for(x=0;x<W;x++)g[y].push(" ");}
 for(var arm=0;arm<3;arm++){for(var r=0;r<12.5;r+=0.045){var a=r*0.9+arm*2.0944;x=Math.round(W/2+Math.cos(a)*r*1.9);y=Math.round(H/2+Math.sin(a)*r*0.95);if(x>=0&&x<W&&y>=0&&y<H){i=Math.min(C.length-1,Math.floor((1-r/12.5)*(C.length-1)));g[y][x]=C.charAt(i);}}}
 return g.map(function(row){return row.join("");}).join("\n");
}

var nodes=document.querySelectorAll("[data-t]");
for(var n=0;n<nodes.length;n++)nodes[n].textContent=t[nodes[n].getAttribute("data-t")];
$("#u").placeholder=t.paste;
$("#swirl").textContent=swirl();
renderOpts();
document.addEventListener("visibilitychange",function(){if(!document.hidden&&!locked)poll();});
setInterval(function(){tick++;if(last.length)render(last);},120);
if(!K)lock();else poll();
})();
</script>
</body>
</html>
'@

<# Ancienne page v6.0 (désactivée, gardée en commentaire)

$WebHtml = @'
<!doctype html>
<html lang="{{LANG}}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#05070C">
<meta name="referrer" content="no-referrer">
<link rel="icon" href="data:,">
<title>Maelström</title>
<style>
:root{--bg:#05070C;--panel:#080B13;--line:#161C26;--line2:#2E3540;--hi:#ECF0F5;--fg:#C6CDD7;--dim:#707A8A;--acc:#7DB6DE;--ok:#7EC898;--err:#E47070;--warn:#E2BC70;--mono:ui-monospace,"Cascadia Mono","Cascadia Code","SF Mono",Menlo,Consolas,"Roboto Mono","Liberation Mono",monospace}
*{box-sizing:border-box}
[hidden]{display:none!important}
html,body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--mono);-webkit-font-smoothing:antialiased;-webkit-text-size-adjust:100%}
body{min-height:100vh;background:radial-gradient(1100px 480px at 50% -220px,rgba(125,182,222,.08),transparent 70%),var(--bg)}
body::after{content:"";position:fixed;inset:0;pointer-events:none;background:repeating-linear-gradient(0deg,rgba(255,255,255,.014) 0 1px,transparent 1px 3px)}
.wrap{max-width:860px;margin:0 auto;padding:max(30px,env(safe-area-inset-top)) 18px max(40px,env(safe-area-inset-bottom))}
.logo{margin:0;font-family:var(--mono);font-size:clamp(4.4px,1.8vw,13px);line-height:1;white-space:pre;text-align:center;overflow:hidden;user-select:none;font-variant-ligatures:none}
.logo i{font-style:normal;color:#485262}
.tag{margin:16px 0 0;text-align:center;font-size:12px;letter-spacing:.42em;text-transform:uppercase;color:var(--fg)}
.tag b{color:var(--line2);font-weight:400}
.tag em{font-style:normal;color:var(--acc);letter-spacing:.06em;margin-left:.5em}
.status{display:flex;flex-wrap:wrap;gap:6px 18px;justify-content:space-between;margin:28px 0 0;padding:0 0 10px;border-bottom:1px solid var(--line2);font-size:12px;color:var(--dim)}
.dot{color:var(--ok)}.dot.off{color:var(--err)}
section{margin-top:28px}
h2{margin:0 0 12px;font-size:13px;font-weight:600;color:var(--hi);letter-spacing:.06em}
h2::before{content:"◆ ";color:var(--acc)}
h2 small{color:var(--dim);font-weight:400;margin-left:8px;font-size:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:3px;padding:16px;position:relative}
.card::before,.card::after{content:"";position:absolute;width:10px;height:10px;border-color:var(--line2);border-style:solid;pointer-events:none}
.card::before{top:-1px;left:-1px;border-width:1px 0 0 1px}
.card::after{bottom:-1px;right:-1px;border-width:0 1px 1px 0}
.field{display:flex;align-items:center;gap:10px;border:1px solid var(--line2);background:#04060A;padding:0 8px 0 12px;border-radius:3px}
.field:focus-within{border-color:var(--acc)}
.field>span{color:var(--acc)}
input{flex:1;min-width:0;background:transparent;border:0;outline:0;color:var(--hi);font:inherit;font-size:16px;padding:14px 0}
input::placeholder{color:#4A5363}
.lbl{font-size:11px;color:var(--dim);letter-spacing:.24em;text-transform:uppercase;margin:18px 0 8px}
.row{display:flex;flex-wrap:wrap;gap:8px}
.opt{font:inherit;font-size:13px;color:var(--fg);background:transparent;border:1px solid var(--line2);border-radius:3px;padding:9px 14px;cursor:pointer}
.opt[aria-pressed="true"]{color:var(--bg);background:var(--hi);border-color:var(--hi)}
.note{font-size:11.5px;color:var(--dim);margin-top:10px;line-height:1.5}
.note:empty{display:none}
.go{width:100%;margin-top:18px;font:inherit;font-size:13px;letter-spacing:.32em;text-transform:uppercase;color:var(--bg);background:var(--acc);border:0;border-radius:3px;padding:15px;cursor:pointer}
.go:disabled{opacity:.45}
.msg{min-height:1.2em;margin-top:10px;font-size:12px;color:var(--err)}
.job{display:grid;grid-template-columns:136px 1fr;gap:14px;align-items:start}
.job+.job{margin-top:12px}
.th{width:136px;aspect-ratio:16/9;background:#0B0F18 center/cover no-repeat;border:1px solid var(--line);border-radius:2px}
.bd{min-width:0}
.ti{color:var(--hi);font-size:14px;line-height:1.35;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;word-break:break-word}
.meta{font-size:11.5px;color:var(--dim);margin-top:4px}
.bar{margin-top:10px;font-size:12px;white-space:nowrap;overflow:hidden}
.bar:empty{display:none}
.bar .a{color:var(--acc)}.bar .t{color:#2A313C}.bar b{color:var(--hi);font-weight:400}
.info{font-size:11.5px;color:var(--dim);margin-top:5px;line-height:1.5;word-break:break-word}
.acts{display:flex;gap:8px;margin-top:12px;flex-wrap:wrap}
.acts:empty{display:none}
.save{font:inherit;font-size:12.5px;text-decoration:none;color:var(--bg);background:var(--ok);padding:9px 14px;border-radius:3px;letter-spacing:.04em}
.x{font:inherit;font-size:12.5px;color:var(--dim);background:transparent;border:1px solid var(--line2);padding:8px 12px;border-radius:3px;cursor:pointer}
.ok{color:var(--ok)}.err{color:var(--err)}.warn{color:var(--warn)}
.empty{color:var(--dim);font-size:13px;text-align:center;padding:26px 0}
footer{margin-top:36px;padding-top:12px;border-top:1px solid var(--line);font-size:11px;color:var(--dim);display:flex;justify-content:space-between;flex-wrap:wrap;gap:6px;word-break:break-all}
.lock{position:fixed;inset:0;background:rgba(5,7,12,.97);display:none;align-items:center;justify-content:center;text-align:center;padding:30px;color:var(--fg);font-size:14px;line-height:1.7}
.lock.on{display:flex}
.lock .ic{color:var(--acc);font-size:26px;margin-bottom:12px}
@media (max-width:540px){.job{grid-template-columns:1fr}.th{width:100%}.tag{letter-spacing:.3em;font-size:11px}}
</style>
</head>
<body>
<div class="wrap">
<pre class="logo" aria-label="Maelström">{{LOGO}}</pre>
<p class="tag"><b>[</b> {{TAG}} <b>]</b><em>v{{VER}}</em></p>
<div class="status"><span id="st">…</span><span id="clock"></span></div>

<section>
<h2 data-t="newdl"></h2>
<form id="f" class="card" autocomplete="off" novalidate>
<label class="field"><span>›</span><input id="u" type="url" inputmode="url" enterkeyhint="go" spellcheck="false" autocapitalize="off"><button type="button" id="pb" class="x" hidden></button></label>
<div class="lbl" data-t="type"></div>
<div class="row" id="kind"><button type="button" class="opt" data-v="video">▶ <span data-t="video"></span></button><button type="button" class="opt" data-v="audio">♪ <span data-t="audio"></span></button></div>
<div class="lbl" id="fmtl"></div>
<div class="row" id="fmts"></div>
<div class="note" id="note"></div>
<button class="go" id="go" type="submit">⬇&nbsp; <span data-t="go"></span></button>
<div class="msg" id="msg"></div>
</form>
</section>

<section>
<h2><span data-t="queue"></span><small id="count"></small></h2>
<div id="jobs"></div>
<div class="empty" id="empty" data-t="empty"></div>
</section>

<footer><span id="folder"></span><span>MAELSTRÖM · v{{VER}}</span></footer>
</div>
<div class="lock" id="lock"><div><div class="ic">▣</div><span data-t="lock"></span></div></div>

<script>
(function(){
"use strict";
var LANG="{{LANG}}";
var T={
fr:{newdl:"Nouveau téléchargement",paste:"Collez un lien (YouTube, TikTok, SoundCloud…)",type:"Type",video:"Vidéo",audio:"Audio",quality:"Qualité",format:"Format",max:"Max",orig:"Original",go:"Télécharger",queue:"File",empty:"Aucun téléchargement pour l'instant.",queued:"En attente…",start:"Démarrage…",fin:"Finalisation (fusion / conversion)…",done:"Terminé",save:"Enregistrer sur l'appareil",cancel:"Annuler",remove:"Retirer",cancelled:"Annulé",error:"Échec",stream:"flux",online:"Connecté",offline:"Hors ligne · reconnexion…",badurl:"Lien invalide.",lock:"Accès refusé. Sur le PC : Paramètres → Ouvrir le port, puis scannez le QR code.",folder:"Copie sur le PC",maxnote:"« Max » peut donner du VP9 ou de l'AV1, que certains téléphones lisent mal. 1080p reste en H.264, lisible partout.",pastebtn:"Coller"},
en:{newdl:"New download",paste:"Paste a link (YouTube, TikTok, SoundCloud…)",type:"Type",video:"Video",audio:"Audio",quality:"Quality",format:"Format",max:"Max",orig:"Original",go:"Download",queue:"Queue",empty:"No downloads yet.",queued:"Waiting…",start:"Starting…",fin:"Finalizing (merge / conversion)…",done:"Done",save:"Save to device",cancel:"Cancel",remove:"Remove",cancelled:"Cancelled",error:"Failed",stream:"stream",online:"Connected",offline:"Offline · reconnecting…",badurl:"Invalid link.",lock:"Access denied. On the PC: Settings → Open the port, then scan the QR code.",folder:"Copy on the PC",maxnote:"“Max” may give VP9 or AV1, which some phones play poorly. 1080p stays H.264 and plays everywhere.",pastebtn:"Paste"}
};
var t=T[LANG]||T.en;
function $(s){return document.querySelector(s);}
var K="";
try{var qs=new URLSearchParams(location.search);K=qs.get("k")||"";if(K){localStorage.setItem("ms_k",K);history.replaceState(null,"","/");}else{K=localStorage.getItem("ms_k")||"";}}catch(e){}
var kind="video",fmt={video:"1080",audio:"mp3"};
var OPTS={video:[["max",t.max],["1080","1080p"],["720","720p"]],audio:[["mp3","MP3 320"],["m4a","M4A"],["best",t.orig]]};
var SP="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏",tick=0,last=[],els={},timer=null,locked=false;
function esc(s){return String(s==null?"":s).replace(/[&<>"']/g,function(c){return{"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c];});}
function sz(b){if(!(b>=0))return"?";var u=["B","KB","MB","GB"],i=0;while(b>=1024&&i<3){b/=1024;i++;}return b.toFixed(i>=2?1:0)+" "+u[i];}
function pad(n){return(n<10?"0":"")+n;}
function dur(s){s=Math.max(0,Math.round(s));var h=Math.floor(s/3600),m=Math.floor(s%3600/60),x=s%60;return(h?h+":"+pad(m):m)+":"+pad(x);}
function rep(c,n){return n>0?new Array(n+1).join(c):"";}
function mkbar(f,n){n=n||26;if(f<0){var g=7,p=(tick%(n+g))-g,a=Math.max(0,p),b=Math.min(n,p+g);if(b<a)b=a;return"<span class=\"t\">"+rep("━",a)+"</span><span class=\"a\">"+rep("━",b-a)+"</span><span class=\"t\">"+rep("━",n-b)+"</span>";}var k=Math.round(Math.min(1,f)*n);return"<span class=\"a\">"+rep("━",k)+"</span><span class=\"t\">"+rep("━",n-k)+"</span>";}
function label(j){if(j.kind==="audio"){return j.fmt==="mp3"?"MP3 320":(j.fmt==="m4a"?"M4A":t.orig);}return j.fmt==="max"?t.max:j.fmt+"p";}
function msg(s){$("#msg").textContent=s||"";}
function lock(){locked=true;clearTimeout(timer);$("#lock").classList.add("on");}
function api(path,opt){return fetch(path+(path.indexOf("?")<0?"?":"&")+"k="+encodeURIComponent(K),opt).then(function(r){if(r.status===403){lock();throw new Error("key");}return r;});}
function btn(id,txt){return"<button type=\"button\" class=\"x\" data-c=\""+id+"\">"+esc(txt)+"</button>";}

function renderOpts(){
 var bs=document.querySelectorAll("#kind .opt");
 for(var i=0;i<bs.length;i++)bs[i].setAttribute("aria-pressed",String(bs[i].getAttribute("data-v")===kind));
 $("#fmtl").textContent=kind==="video"?t.quality:t.format;
 $("#fmts").innerHTML=OPTS[kind].map(function(o){return"<button type=\"button\" class=\"opt\" data-v=\""+o[0]+"\" aria-pressed=\""+(fmt[kind]===o[0])+"\">"+esc(o[1])+"</button>";}).join("");
 $("#note").textContent=(kind==="video"&&fmt.video==="max")?t.maxnote:"";
}
$("#kind").addEventListener("click",function(e){var b=e.target.closest(".opt");if(b){kind=b.getAttribute("data-v");renderOpts();}});
$("#fmts").addEventListener("click",function(e){var b=e.target.closest(".opt");if(b){fmt[kind]=b.getAttribute("data-v");renderOpts();}});
$("#f").addEventListener("submit",function(e){
 e.preventDefault();var u=$("#u").value.trim();
 if(!/^https?:\/\/\S+$/i.test(u)){msg(t.badurl);return;}
 var go=$("#go");go.disabled=true;msg("");
 api("/api/add",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({url:u,kind:kind,fmt:fmt[kind]})})
 .then(function(r){if(!r.ok)throw new Error("bad");$("#u").value="";$("#u").blur();poll();})
 .catch(function(x){if(!x||x.message!=="key")msg(t.badurl);})
 .then(function(){go.disabled=false;});
});
$("#jobs").addEventListener("click",function(e){var b=e.target.closest("[data-c]");if(!b)return;b.disabled=true;api("/api/cancel?id="+b.getAttribute("data-c"),{method:"POST"}).then(function(){poll();}).catch(function(){});});

function set(el,sel,html){if(el._c[sel]!==html){el._c[sel]=html;el.querySelector(sel).innerHTML=html;}}
function render(list){
 var box=$("#jobs"),seen={},spin=SP.charAt(tick%SP.length);
 $("#empty").style.display=list.length?"none":"";
 $("#count").textContent=list.length?"· "+list.length:"";
 list.forEach(function(j,i){
  seen[j.id]=1;var el=els[j.id];
  if(!el){el=document.createElement("div");el.className="card job";el._c={};el.innerHTML="<div class=\"th\"></div><div class=\"bd\"><div class=\"ti\"></div><div class=\"meta\"></div><div class=\"bar\"></div><div class=\"info\"></div><div class=\"acts\"></div></div>";els[j.id]=el;}
  if(box.children[i]!==el)box.insertBefore(el,box.children[i]||null);
  var th=el.querySelector(".th");
  if(j.thumb&&th.getAttribute("data-u")!==j.thumb){th.setAttribute("data-u",j.thumb);th.style.backgroundImage="url(\""+j.thumb.replace(/"/g,"%22")+"\")";}
  var site=(j.site&&j.site!=="NA")?j.site+"  ·  ":"";
  set(el,".ti",esc(j.title||j.url));
  set(el,".meta",esc(site+(j.kind==="audio"?t.audio:t.video)+" "+label(j)));
  var bar="",info="",acts="";
  if(j.state==="run"){
   var f=(j.tot>0&&j.dl>=0)?j.dl/j.tot:-1;
   if(f>=0.999){bar=mkbar(-1);info=spin+"  "+esc(t.fin);}
   else if(j.dl<0){bar=mkbar(-1);info=spin+"  "+esc(t.start);}
   else{
    bar=mkbar(f)+"  <b>"+(f>=0?(f*100).toFixed(1)+" %":"")+"</b>";
    var p=[sz(j.dl)+(j.tot>0?" / "+sz(j.tot):"")];
    if(j.spd>0)p.push(sz(j.spd)+"/s");
    if(j.eta>=0)p.push("ETA "+dur(j.eta));
    if(j.stage>1)p.push(t.stream+" "+j.stage);
    info=esc(p.join("  ·  "));
   }
   acts=btn(j.id,t.cancel);
  }else if(j.state==="queued"){info=spin+"  "+esc(t.queued);acts=btn(j.id,t.cancel);}
  else if(j.state==="done"){
   bar=mkbar(1);
   info="<span class=\"ok\">✔ "+esc(t.done)+"</span>  ·  "+esc(j.name)+(j.size>=0?"  ·  "+sz(j.size):"");
   acts="<a class=\"save\" href=\"/f/"+j.id+"?k="+encodeURIComponent(K)+"\" download>↓ "+esc(t.save)+"</a>"+btn(j.id,t.remove);
  }
  else if(j.state==="error"){info="<span class=\"err\">✖ "+esc(t.error)+"</span>"+(j.err?"  ·  "+esc(j.err):"");acts=btn(j.id,t.remove);}
  else{info="<span class=\"warn\">■ "+esc(t.cancelled)+"</span>";acts=btn(j.id,t.remove);}
  set(el,".bar",bar);set(el,".info",info);set(el,".acts",acts);
 });
 for(var id in els){if(!seen[id]){els[id].remove();delete els[id];}}
}
function poll(){
 clearTimeout(timer);if(locked)return;
 api("/api/jobs",{cache:"no-store"}).then(function(r){return r.json();}).then(function(d){
  $("#st").innerHTML="<span class=\"dot\">●</span> "+esc(t.online)+"  ·  "+esc(d.pc);
  $("#folder").textContent=t.folder+" : "+d.folder;
  last=d.jobs||[];render(last);timer=setTimeout(poll,1000);
 }).catch(function(){if(locked)return;$("#st").innerHTML="<span class=\"dot off\">●</span> "+esc(t.offline);timer=setTimeout(poll,2500);});
}

var nodes=document.querySelectorAll("[data-t]");
for(var i=0;i<nodes.length;i++)nodes[i].textContent=t[nodes[i].getAttribute("data-t")];
$("#u").placeholder=t.paste;
if(navigator.clipboard&&navigator.clipboard.readText&&window.isSecureContext){var pb=$("#pb");pb.hidden=false;pb.textContent=t.pastebtn;pb.addEventListener("click",function(){navigator.clipboard.readText().then(function(s){$("#u").value=s.trim();}).catch(function(){});});}
renderOpts();
setInterval(function(){tick++;var d=new Date();$("#clock").textContent=pad(d.getHours())+":"+pad(d.getMinutes())+":"+pad(d.getSeconds());if(last.length)render(last);},150);
if(!K)lock();else poll();
})();
</script>
</body>
</html>
'@

#>

function Logo-Html {
    $sb = New-Object Text.StringBuilder
    for ($gy = 0; $gy -lt $LogoPlain.Count; $gy++) {
        $cc = $grad[$gy]
 [void]$sb.Append(('<span style="color:#{0:X2}{1:X2}{2:X2}">' -f [int]$cc[0], [int]$cc[1], [int]$cc[2]))
        $inS = $false
        foreach ($ch in ([string]$LogoPlain[$gy]).ToCharArray()) {
     if ($ch -eq [char]'█') { if ($inS) { [void]$sb.Append('</i>'); $inS = $false } }
     elseif ($ch -ne [char]' ' -and -not $inS) { [void]$sb.Append('<i>'); $inS = $true }
     [void]$sb.Append($ch)
        }
        if ($inS) { [void]$sb.Append('</i>') }
        [void]$sb.Append('</span>')
        if ($gy -lt $LogoPlain.Count - 1) { [void]$sb.Append("`n") }
    }
    return $sb.ToString()
}

function Web-Page {
    $lang = if ([string]$Cfg.lang -eq 'fr') { 'fr' } else { 'en' }
    $tag = [Net.WebUtility]::HtmlEncode([string](L 'tag'))
    return $WebHtml.Replace('{{LOGO}}', (Logo-Html)).Replace('{{TAG}}', $tag).Replace('{{VER}}', [string]$App.Ver).Replace('{{LANG}}', $lang)
}

function Get-LanIp {
    $best = $null
    try {
        foreach ($ni in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
     if ($ni.OperationalStatus -ne 'Up' -or $ni.NetworkInterfaceType -eq 'Loopback') { continue }
            $ipp = $ni.GetIPProperties()
            $gw = @($ipp.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -ne '0.0.0.0' }).Count -gt 0
     foreach ($ua in $ipp.UnicastAddresses) {
  if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
         $s = $ua.Address.ToString()
         if ($s.StartsWith('169.254.') -or $s.StartsWith('127.')) { continue }
  if ($gw) { return $s }
  if (-not $best) { $best = $s }
     }
        }
    } catch {}
    if ($best) { return $best }
    return '127.0.0.1'
}

function Qr-Lines([string]$text, [int]$q) {
    if (-not ('MsQr' -as [type])) { return @{ lines = @(); width = 0 } }
    $qr = [MsQr]::Encode($text); $n = $qr.GetLength(0)
    $ink = $Esc + '[38;2;0;0;0m' + $Esc + '[48;2;255;255;255m'
    $lines = @()
    for ($y = -$q; $y -lt $n + $q; $y += 2) {
 $sb = New-Object Text.StringBuilder
        for ($x = -$q; $x -lt $n + $q; $x++) {
            $t1 = ($y -ge 0 -and $y -lt $n -and $x -ge 0 -and $x -lt $n -and $qr[$y, $x])
            $y2 = $y + 1
     $t2 = ($y2 -ge 0 -and $y2 -lt $n -and $x -ge 0 -and $x -lt $n -and $qr[$y2, $x])
     if ($t1 -and $t2) { [void]$sb.Append('█') } elseif ($t1) { [void]$sb.Append('▀') } elseif ($t2) { [void]$sb.Append('▄') } else { [void]$sb.Append(' ') }
 }
        $lines += $ink + $sb.ToString() + $Rst
    }
    return @{ lines = $lines; width = $n + 2 * $q }
}

<# Ancien serveur v6.0 (PowerShell mono-thread) — désactivé, remplacé par MsWeb plus bas
# --- HTTP minimal ---
function Url-Dec([string]$s) { try { return [Uri]::UnescapeDataString($s.Replace('+', ' ')) } catch { return $s } }
function Parse-Query([string]$qs) {
    $h = @{}
    foreach ($pp in $qs.Split('&')) {
        if (-not $pp) { continue }
 $i = $pp.IndexOf('=')
        if ($i -lt 0) { $h[(Url-Dec $pp)] = '' } else { $h[(Url-Dec $pp.Substring(0, $i))] = Url-Dec $pp.Substring($i + 1) }
    }
    return $h
}
function Http-Read($ns) {
    $lat = [Text.Encoding]::GetEncoding(28591)
    $buf = New-Object byte[] 16384; $ms = New-Object IO.MemoryStream; $end = -1
    while ($end -lt 0) {
 $n = $ns.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return $null }
 $ms.Write($buf, 0, $n)
        if ($ms.Length -gt 65536) { return $null }
 $end = $lat.GetString($ms.ToArray()).IndexOf("`r`n`r`n")
    }
    $all = $ms.ToArray()
    $lines = $lat.GetString($all, 0, $end) -split "`r`n"
    $rl = $lines[0].Split(' ')
    if ($rl.Count -lt 2) { return $null }
    $hd = @{}
    foreach ($hl in @($lines | Select-Object -Skip 1)) { $i = $hl.IndexOf(':'); if ($i -gt 0) { $hd[$hl.Substring(0, $i).Trim().ToLower()] = $hl.Substring($i + 1).Trim() } }
    $len = 0; if ($hd['content-length']) { [void][int]::TryParse([string]$hd['content-length'], [ref]$len) }
    $len = [Math]::Min($len, 65536)
    $body = New-Object IO.MemoryStream
    $b0 = $end + 4
    if ($all.Length -gt $b0) { $body.Write($all, $b0, $all.Length - $b0) }
    while ($body.Length -lt $len) { $n = $ns.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $body.Write($buf, 0, $n) }
    $target = $rl[1]; $path = $target; $qs = ''
    $qi = $target.IndexOf('?'); if ($qi -ge 0) { $path = $target.Substring(0, $qi); $qs = $target.Substring($qi + 1) }
    return @{ method = $rl[0].ToUpper(); path = $path; q = (Parse-Query $qs); body = [Text.Encoding]::UTF8.GetString($body.ToArray()) }
}
function Http-Send($ns, [int]$code, [string]$type, [byte[]]$body) {
    $reason = @{ 200 = 'OK'; 204 = 'No Content'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found' }[$code]
    if (-not $reason) { $reason = 'Error' }
    if ($null -eq $body) { $body = New-Object byte[] 0 }
    $h = "HTTP/1.1 $code $reason`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`nConnection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($h)
    $ns.Write($hb, 0, $hb.Length)
    if ($body.Length) { $ns.Write($body, 0, $body.Length) }
}
function Http-Text($ns, [int]$code, [string]$type, [string]$s) { Http-Send $ns $code $type ([Text.Encoding]::UTF8.GetBytes($s)) }

# --- Tâches lancées depuis le téléphone ---
function Web-Find([string]$id) { foreach ($x in $Web.jobs) { if ($x.id -eq $id) { return $x } }; return $null }
function Web-View($j) {
    $nm = ''; if ($j.file) { $nm = [IO.Path]::GetFileName([string]$j.file) }
    return @{ id = $j.id; state = $j.state; url = $j.url; kind = $j.kind; fmt = $j.fmt; title = $j.title; thumb = $j.thumb; site = $j.site
       dl = [double]$j.dl; tot = [double]$j.tot; spd = [double]$j.spd; eta = [double]$j.eta; stage = [int]$j.stage; name = $nm; size = [double]$j.size; err = $j.err }
}
function Web-Json {
    $list = New-Object Collections.ArrayList
    for ($i = $Web.jobs.Count - 1; $i -ge 0; $i--) { [void]$list.Add((Web-View $Web.jobs[$i])) }
    return $Web.ser.Serialize(@{ jobs = $list; folder = [string]$Cfg.out; pc = [string]$env:COMPUTERNAME; ver = [string]$App.Ver })
}
function Web-Launch($j) {
    try {
 if (-not $St.YT) { throw 'yt-dlp introuvable' }
        $j.tmp = Join-Path $Tmp ('w_' + $j.id)
 New-Item -ItemType Directory -Force -Path $j.tmp | Out-Null
 if (-not (Test-Path $Cfg.out)) { New-Item -ItemType Directory -Force -Path $Cfg.out | Out-Null }
 $x = if ($j.kind -eq 'audio') { Audio-Args $j.fmt } else { Video-Args ($(if ($j.fmt -eq 'max') { 0 } else { [int]$j.fmt })) }
        $a = @('--newline', '--no-colors', '--progress', '--no-warnings', '--ignore-config', '--no-mtime', '--no-playlist',
        '-P', "home:$($Cfg.out)", '-P', "temp:$($j.tmp)", '-o', '%(title).200B.%(ext)s',
        '--progress-template', 'download:MSP|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s',
        '--print', 'before_dl:MST|%(extractor_key)s|%(thumbnail)s|%(title)s',
        '--print', 'after_move:MSF|%(filepath)s', '--no-simulate')
        if ($St.FFDir) { $a += '--ffmpeg-location', $St.FFDir }
        $a += $x
        $a += '--', $j.url
        $j.p = Start-Proc $St.YT $a
        $j.to = $j.p.StandardOutput.ReadLineAsync(); $j.te = $j.p.StandardError.ReadLineAsync()
        $j.od = $false; $j.ed = $false; $j.state = 'run'
    } catch { $j.state = 'error'; $j.err = [string]$_.Exception.Message; $j.p = $null }
}
function Web-Line($j, [string]$line) {
    if ($line.StartsWith('MSP|')) {
        $f = $line.Split('|')
        $d = Num $f[1]; $t = Num $f[2]; if ($t -le 0) { $t = Num $f[3] }
        if ($d -ge 0 -and $j.prev -gt 1048576 -and $d -lt $j.prev * 0.5) { $j.stage = [int]$j.stage + 1 }
 if ($d -ge 0) { $j.prev = $d }
        $j.dl = $d; $j.tot = $t; $j.spd = Num $f[4]; $j.eta = Num $f[5]
    } elseif ($line.StartsWith('MST|')) {
        $f = $line.Split([char[]]@([char]'|'), 4)
        if ($f.Count -ge 4) { $j.site = $f[1]; if ($f[2] -match '^https?://') { $j.thumb = $f[2] }; $j.title = $f[3] }
    } elseif ($line.StartsWith('MSF|')) { $j.files = @($j.files) + $line.Substring(4).Trim() }
    elseif ($line -match '^ERROR') { $j.err = ($line -replace '^ERROR:\s*', '') }
}
function Web-PollJob($j) {
    $p = $j.p
    for ($g = 0; $g -lt 400; $g++) {
        $any = $false
        if (-not $j.od -and $j.to.IsCompleted) {
     $l = $null; try { $l = $j.to.Result } catch {}
     if ($null -eq $l) { $j.od = $true } else { Web-Line $j $l; $j.to = $p.StandardOutput.ReadLineAsync() }
     $any = $true
        }
        if (-not $j.ed -and $j.te.IsCompleted) {
     $l = $null; try { $l = $j.te.Result } catch {}
     if ($null -eq $l) { $j.ed = $true } else { Web-Line $j $l; $j.te = $p.StandardError.ReadLineAsync() }
     $any = $true
        }
        if (-not $any) { break }
    }
    if ($j.od -and $j.ed) {
        $p.WaitForExit()
        if ($j.state -eq 'run') {
     if ($p.ExitCode -eq 0 -and @($j.files).Count) {
         $j.file = [string]@($j.files)[-1]
         try { $j.size = [double](Get-Item -LiteralPath $j.file).Length } catch {}
         $j.state = 'done'
     } else {
         $j.state = 'error'; if (-not $j.err) { $j.err = 'yt-dlp: code ' + $p.ExitCode }
     }
        }
        try { $p.Dispose() } catch {}
        $j.p = $null
 if ($j.tmp) { Remove-Item -LiteralPath $j.tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
function Web-Pump {
    $busy = $false
    foreach ($j in @($Web.jobs)) { if ($j.p) { Web-PollJob $j }; if ($j.state -eq 'run') { $busy = $true } }
    if (-not $busy) { foreach ($j in @($Web.jobs)) { if ($j.state -eq 'queued') { Web-Launch $j; break } } }
}

function Draw-WebStatus([int]$tick) {
    $x = $Web.sx; $y = $Web.sy; $wd = [Math]::Max(20, $Web.sw)
    $out = New-Object 'Collections.Generic.List[string]'
    $out.Add($Col.Ok + '●  ' + $Col.Fg + ((L 'w_listen') -f $Web.port) + $Col.Dim + '   ·   ' + ((L 'w_stats') -f $Web.sent))
    if ($Web.note) { $out.Add($Col.Acc + '⇅  ' + $Col.Fg + (Trunc $Web.note ($wd - 4))) }
    elseif ($Web.clock.ElapsedMilliseconds - $Web.peerT -lt 5000) { $out.Add($Col.Ok + '⇄  ' + $Col.Fg + ((L 'w_conn') -f $Web.peer)) }
    else { $out.Add($Col.Dim + '○  ' + (L 'w_noconn')) }
    $out.Add('')
    $recent = @($Web.jobs | Select-Object -Last 4)
    if ($recent.Count -eq 0) { $out.Add($Col.Dim + (Trunc (L 'w_wait') $wd)) }
    for ($i = $recent.Count - 1; $i -ge 0; $i--) {
 $j = $recent[$i]; $tail = ''
        switch ([string]$j.state) {
     'run'    { $ic = $Col.Acc + $Spin[$tick % $Spin.Count]; if ($j.tot -gt 0 -and $j.dl -ge 0) { $tail = '{0,7:N1} %' -f ([Math]::Min(1, $j.dl / $j.tot) * 100) } }
     'queued' { $ic = $Col.Dim + '·' }
     'done'   { $ic = $Col.Ok + '✔' }
     'error'  { $ic = $Col.Err + '✖' }
     default  { $ic = $Col.Warn + '■' }
        }
        $out.Add($ic + '  ' + $Col.Fg + (Trunc ([string](First $j.title $j.url)) ($wd - 13)) + $Col.Dim + $tail)
    }
    while ($out.Count -lt 7) { $out.Add('') }
    $out.Add('')
    $out.Add($Col.Dim + (Trunc (L 'w_hint') $wd))
    for ($i = 0; $i -lt $out.Count; $i++) { try { [Console]::SetCursorPosition($x, $y + $i); Wr ($out[$i] + $Rst + $Eol) } catch {} }
}

function Web-SendFile($ns, $j, [string]$method) {
    $f = [string]$j.file
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { Http-Text $ns 404 'text/plain; charset=utf-8' 'Not found'; return }
    $fi = Get-Item -LiteralPath $f; $name = $fi.Name
    $sa = New-Object Text.StringBuilder
    foreach ($ch in $name.ToCharArray()) { $v = [int]$ch; if ($v -lt 32 -or $v -gt 126 -or $ch -eq [char]'"' -or $ch -eq [char]'\') { [void]$sa.Append('_') } else { [void]$sa.Append($ch) } }
    $type = switch ($fi.Extension.ToLower()) {
        '.mp4' { 'video/mp4' } '.m4a' { 'audio/mp4' } '.mp3' { 'audio/mpeg' } '.webm' { 'video/webm' } '.mkv' { 'video/x-matroska' }
        '.opus' { 'audio/ogg' } '.ogg' { 'audio/ogg' } '.flac' { 'audio/flac' } '.wav' { 'audio/wav' } default { 'application/octet-stream' }
    }
    $h = "HTTP/1.1 200 OK`r`nContent-Type: $type`r`nContent-Length: $($fi.Length)`r`nContent-Disposition: attachment; filename=`"$($sa.ToString())`"; filename*=UTF-8''$([Uri]::EscapeDataString($name))`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nConnection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($h); $ns.Write($hb, 0, $hb.Length)
    if ($method -eq 'HEAD') { return }
    $Web.note = (L 'w_send') -f $name; Draw-WebStatus 0
    $fs = [IO.File]::Open($f, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $fs.CopyTo($ns, 262144); $Web.sent = [int]$Web.sent + 1 } finally { $fs.Close(); $Web.note = '' }
}

function Web-Handle($c) {
    $ns = $c.GetStream(); $ns.ReadTimeout = 4000; $ns.WriteTimeout = 120000
    $rq = Http-Read $ns
    if (-not $rq) { return }
    try { $ra = $c.Client.RemoteEndPoint.Address; if (-not [Net.IPAddress]::IsLoopback($ra)) { $Web.peer = $ra.ToString(); $Web.peerT = $Web.clock.ElapsedMilliseconds } } catch {}
    $path = $rq.path; $json = 'application/json; charset=utf-8'
    if ($path -eq '/' -or $path -eq '/index.html') { Http-Text $ns 200 'text/html; charset=utf-8' $Web.html; return }
    if ($path -eq '/favicon.ico') { Http-Send $ns 204 'image/x-icon' $null; return }
    if ([string]$rq.q['k'] -cne $Web.key) { Http-Text $ns 403 $json '{"error":"key"}'; return }
    if ($path -eq '/api/jobs') { Http-Text $ns 200 $json (Web-Json); return }
    if ($path -eq '/api/add' -and $rq.method -eq 'POST') {
 $d = $null; try { $d = $Web.ser.DeserializeObject($rq.body) } catch {}
        $u = ([string](G $d 'url')).Trim()
        if ($u -notmatch '^https?://\S+$') { Http-Text $ns 400 $json '{"error":"url"}'; return }
        $kind = if ([string](G $d 'kind') -eq 'audio') { 'audio' } else { 'video' }
        $fmt = [string](G $d 'fmt')
 if ($kind -eq 'audio') { if (@('mp3', 'm4a', 'best') -notcontains $fmt) { $fmt = 'mp3' } }
        elseif (@('max', '2160', '1080', '720') -notcontains $fmt) { $fmt = '1080' }
        $j = @{ id = [guid]::NewGuid().ToString('N').Substring(0, 10); url = $u; kind = $kind; fmt = $fmt; state = 'queued'
         title = ''; thumb = ''; site = ''; dl = -1.0; tot = -1.0; spd = -1.0; eta = -1.0; stage = 1; prev = 0.0
         files = @(); file = ''; size = -1.0; err = ''; p = $null; to = $null; te = $null; od = $false; ed = $false; tmp = '' }
 [void]$Web.jobs.Add($j)
        Http-Text $ns 200 $json ($Web.ser.Serialize(@{ id = $j.id })); return
    }
    if ($path -eq '/api/cancel' -and $rq.method -eq 'POST') {
 $j = Web-Find ([string]$rq.q['id'])
        if ($j) {
            if ($j.state -eq 'run') { if ($j.p) { Kill-Tree $j.p }; $j.state = 'cancel' }
            elseif ($j.state -eq 'queued') { $j.state = 'cancel' }
     elseif (-not $j.p) { [void]$Web.jobs.Remove($j) }
 }
        Http-Text $ns 200 $json '{"ok":true}'; return
    }
    if ($path -match '^/f/([0-9a-f]{10})$') {
        $j = Web-Find $Matches[1]
        if ($j -and $j.state -eq 'done') { Web-SendFile $ns $j $rq.method } else { Http-Text $ns 404 'text/plain; charset=utf-8' 'Not found' }
 return
    }
    Http-Text $ns 404 'text/plain; charset=utf-8' 'Not found'
}

function Flow-Web {
    if (-not (Ensure-Tools)) { return }
    if (-not $Cfg.webkey) {
 $abc = 'abcdefghjkmnpqrstuvwxyz23456789'
 $Cfg.webkey = -join (1..10 | ForEach-Object { $abc[(Get-Random -Maximum $abc.Length)] })
 Save-Cfg
    }
    $base = [int]$Cfg.port; if ($base -lt 1024 -or $base -gt 65000) { $base = 8765 }
    $lst = $null; $port = 0
    for ($pt = $base; $pt -lt $base + 20; $pt++) {
        try { $tl = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $pt); $tl.Start(); $lst = $tl; $port = $pt; break } catch {}
    }
    if (-not $lst) { Show-Fail (L 'w_fail') ''; return }

    $ip = Get-LanIp
    $url = 'http://' + $ip + ':' + $port + '/?k=' + $Cfg.webkey
    $Web.key = [string]$Cfg.webkey; $Web.port = $port; $Web.sent = 0; $Web.note = ''; $Web.peer = ''; $Web.peerT = -100000
    $Web.jobs = New-Object Collections.ArrayList; $Web.conns = New-Object Collections.ArrayList
    $Web.ser = New-Object Web.Script.Serialization.JavaScriptSerializer
    $Web.clock = [Diagnostics.Stopwatch]::StartNew()
    $Web.html = Web-Page

    Draw-Header -Compact
    $m = ' ' * $St.M; $w = [Console]::WindowWidth
    Ln ($m + $Col.Acc + '◆ ' + $Col.Hi + (L 'w_title')); Ln ''
    $top = [Console]::CursorTop
    $qr = Qr-Lines $url 2
    $side = ($qr.width -gt 0) -and ($w -ge $St.M + $qr.width + 50)
    $x = if ($side) { $St.M + $qr.width + 4 } else { $St.M }
    $iw = [Math]::Max(20, $w - $x - 2)
    $info = New-Object 'Collections.Generic.List[string]'
    foreach ($pr in @(@($Col.Fg, (L 'w_scan')), @($Col.Acc, $url), @('', ''), @($Col.Dim, (L 'w_same')), @($Col.Dim, (L 'w_fw')))) {
 if (-not $pr[1]) { $info.Add(''); continue }
        foreach ($pc in (Wrap $pr[1] $iw 3)) { $info.Add($pr[0] + $pc) }
    }
    if ($side) {
        $y = $top
        foreach ($ql in $qr.lines) { try { [Console]::SetCursorPosition($St.M, $y) } catch {}; Wr $ql; $y++ }
        $y = $top + 1
        foreach ($il in $info) { try { [Console]::SetCursorPosition($x, $y) } catch {}; Wr ($il + $Rst); $y++ }
        $Web.sy = $y + 1
    } else {
        foreach ($ql in $qr.lines) { Ln ($m + $ql) }
        Ln ''
        foreach ($il in $info) { Ln ($m + $il) }
        Ln ''
        $Web.sy = [Console]::CursorTop
    }
    $Web.sx = $x; $Web.sw = $iw

    $last = -1000; $tick = 0
    Flush-Keys
    try {
        while ($true) {
     $stop = $false
     while ([Console]::KeyAvailable) {
  $k = [Console]::ReadKey($true)
         if ($k.Key -eq 'Escape') { $stop = $true }
         elseif ($k.Key -eq 'Enter') { Start-Process ('http://127.0.0.1:' + $port + '/?k=' + $Cfg.webkey) }
     }
     if ($stop) { break }
     $busy = $false
     while ($lst.Pending()) { [void]$Web.conns.Add(@{ c = $lst.AcceptTcpClient(); t = $Web.clock.ElapsedMilliseconds }); $busy = $true }
     foreach ($cn in @($Web.conns)) {
  $drop = $false
         try {
      if ($cn.c.Available -gt 0) { $busy = $true; $drop = $true; try { Web-Handle $cn.c } catch {} }
      elseif ($Web.clock.ElapsedMilliseconds - $cn.t -gt 8000) { $drop = $true }
         } catch { $drop = $true }
         if ($drop) { try { $cn.c.Close() } catch {}; $Web.conns.Remove($cn) }
     }
     Web-Pump
     if ($Web.clock.ElapsedMilliseconds - $last -ge 250) { $last = $Web.clock.ElapsedMilliseconds; $tick++; Draw-WebStatus $tick }
     if (-not $busy) { Start-Sleep -Milliseconds 20 }
        }
    } finally {
        foreach ($j in @($Web.jobs)) { if ($j.p) { Kill-Tree $j.p } }
 foreach ($cn in @($Web.conns)) { try { $cn.c.Close() } catch {} }
        try { $lst.Stop() } catch {}
 Start-Sleep -Milliseconds 300
        Clean-Tmp
    }
}

# ---------------------------------------------------------------------
#  (fin de l'ancien serveur)
#>

# ---------------------------------------------------------------------
#  Serveur téléphone v6.1 (C#, multi-thread)
#  - chaque connexion est servie sur son propre thread : le TUI ne gèle plus
#  - les fichiers sont téléchargés dans un dossier temporaire du PC, envoyés
#    au téléphone, puis effacés quelques minutes après l'envoi complet
# ---------------------------------------------------------------------
$St.WebErr = ''
try {
Add-Type -IgnoreWarnings -ErrorAction Stop -ReferencedAssemblies ([Web.Script.Serialization.JavaScriptSerializer].Assembly.Location) -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

public class MsJob {
    public string Id = "", Url = "", Kind = "video", Fmt = "1080", State = "queued";
    public string Title = "", Thumb = "", Site = "", FilePath = "", Err = "", Dir = "";
    public double Dl = -1, Tot = -1, Spd = -1, Eta = -1, Prev = 0, Size = -1;
    public int Stage = 1, Active = 0;
    public DateTime LastSend = DateTime.MinValue;
    public Process P;
}

public static class MsWeb {
    class Req {
        public string Method = "GET", Path = "/", Body = "";
 public Dictionary<string, string> Q = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
 public Dictionary<string, string> H = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    }
    const string JS = "application/json; charset=utf-8";
    static readonly object lk = new object();
    static readonly List<MsJob> jobs = new List<MsJob>();
    static TcpListener lst;
    static volatile bool running;
    static volatile int gen;
    public static string Key = "", Html = "", Yt = "", FfDir = "", Root = "", Pc = "", Ver = "";
    public static Dictionary<string, string> Args = new Dictionary<string, string>();
    public static int Port, Sent;
    public static string Peer = "", Note = "", LastError = "";
    public static DateTime PeerAt = DateTime.MinValue;

    public static double PeerAge { get { return (DateTime.Now - PeerAt).TotalSeconds; } }

    public static int Start(int basePort) {
        Stop();
        TcpListener ok = null;
        for (int p = basePort; p < basePort + 20 && ok == null; p++) {
     try { TcpListener l = new TcpListener(IPAddress.Any, p); l.Start(); ok = l; Port = p; }
     catch (Exception ex) { LastError = ex.Message; }
        }
 if (ok == null) return 0;
 lst = ok; Sent = 0; Peer = ""; Note = ""; PeerAt = DateTime.MinValue;
        running = true;
        int g = ++gen;
        Thread a = new Thread(() => AcceptLoop(ok, g)); a.IsBackground = true; a.Start();
        Thread w = new Thread(() => WorkLoop(g)); w.IsBackground = true; w.Start();
 return Port;
    }

    public static void Stop() {
 running = false; gen++;
        TcpListener l = lst; lst = null;
        if (l != null) { try { l.Stop(); } catch { } }
        List<MsJob> all;
        lock (lk) { all = new List<MsJob>(jobs); jobs.Clear(); }
 foreach (MsJob j in all) { Process p = j.P; j.State = "cancel"; if (p != null) KillTree(p); }
 if (all.Count > 0) Thread.Sleep(400);
        foreach (MsJob j in all) DelDir(j.Dir);
    }

    public static string[] Status(int n) {
        List<string> o = new List<string>();
        lock (lk) {
     for (int i = jobs.Count - 1; i >= 0 && o.Count < n; i--) {
  MsJob j = jobs[i];
         double pct = (j.Tot > 0 && j.Dl >= 0) ? Math.Min(100.0, j.Dl * 100.0 / j.Tot) : -1;
         o.Add(j.State + "|" + pct.ToString("0.0", CultureInfo.InvariantCulture) + "|" + (j.Title.Length > 0 ? j.Title : j.Url));
            }
        }
 return o.ToArray();
    }

    // ---------- réseau ----------
    static void AcceptLoop(TcpListener l, int g) {
 while (running && g == gen) {
     TcpClient c;
     try { c = l.AcceptTcpClient(); } catch { break; }
     ThreadPool.QueueUserWorkItem(Serve, c);
 }
    }

    static void Serve(object o) {
        TcpClient c = (TcpClient)o;
 try {
            c.NoDelay = true;
     NetworkStream ns = c.GetStream();
     ns.ReadTimeout = 15000; ns.WriteTimeout = 90000;
            Req r = Read(ns);
     if (r != null) {
  try {
      IPEndPoint ep = (IPEndPoint)c.Client.RemoteEndPoint;
      if (!IPAddress.IsLoopback(ep.Address)) { Peer = ep.Address.ToString(); PeerAt = DateTime.Now; }
         } catch { }
         try { Route(ns, r); } catch (Exception ex) { LastError = ex.Message; }
            }
     // Fermeture propre : évite que le téléphone reçoive un « reset » avant la fin de la réponse
     try {
         c.Client.Shutdown(SocketShutdown.Send);
         ns.ReadTimeout = 1500;
  byte[] t = new byte[1024];
         while (ns.Read(t, 0, t.Length) > 0) { }
     } catch { }
 } catch { }
 finally { try { c.Close(); } catch { } }
    }

    static int FindEnd(byte[] b, int n) {
        for (int i = 0; i + 3 < n; i++) if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
 return -1;
    }
    static string Dec(string s) { try { return Uri.UnescapeDataString(s.Replace('+', ' ')); } catch { return s; } }

    static Req Read(NetworkStream ns) {
        byte[] buf = new byte[8192];
 MemoryStream ms = new MemoryStream();
        int end = -1;
 while (end < 0) {
     int n = ns.Read(buf, 0, buf.Length);
     if (n <= 0) return null;
     ms.Write(buf, 0, n);
     if (ms.Length > 65536) return null;
     end = FindEnd(ms.GetBuffer(), (int)ms.Length);
 }
        byte[] all = ms.ToArray();
        string[] lines = Encoding.ASCII.GetString(all, 0, end).Split(new string[] { "\r\n" }, StringSplitOptions.None);
        string[] rl = lines[0].Split(' ');
        if (rl.Length < 2) return null;
        Req r = new Req();
        r.Method = rl[0].ToUpperInvariant();
        for (int i = 1; i < lines.Length; i++) {
     int k = lines[i].IndexOf(':');
     if (k > 0) r.H[lines[i].Substring(0, k).Trim()] = lines[i].Substring(k + 1).Trim();
        }
 int len = 0; string cl;
        if (r.H.TryGetValue("Content-Length", out cl)) int.TryParse(cl, out len);
 if (len < 0 || len > 65536) len = 0;
        MemoryStream body = new MemoryStream();
        int b0 = end + 4;
        if (all.Length > b0) body.Write(all, b0, all.Length - b0);
 while (body.Length < len) { int n = ns.Read(buf, 0, buf.Length); if (n <= 0) break; body.Write(buf, 0, n); }
 r.Body = Encoding.UTF8.GetString(body.ToArray());
        string target = rl[1];
 int q = target.IndexOf('?');
        r.Path = q >= 0 ? target.Substring(0, q) : target;
 if (q >= 0) {
            foreach (string pp in target.Substring(q + 1).Split('&')) {
         if (pp.Length == 0) continue;
         int e = pp.IndexOf('=');
         r.Q[Dec(e < 0 ? pp : pp.Substring(0, e))] = e < 0 ? "" : Dec(pp.Substring(e + 1));
     }
 }
        return r;
    }

    static void Send(NetworkStream ns, int code, string type, byte[] body, string extra) {
        string reason = code == 200 ? "OK" : code == 204 ? "No Content" : code == 400 ? "Bad Request" : code == 403 ? "Forbidden" : code == 404 ? "Not Found" : code == 416 ? "Range Not Satisfiable" : "Error";
        if (body == null) body = new byte[0];
        string h = "HTTP/1.1 " + code + " " + reason + "\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length
   + "\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n" + (extra ?? "") + "\r\n";
        byte[] hb = Encoding.ASCII.GetBytes(h);
        ns.Write(hb, 0, hb.Length);
        if (body.Length > 0) ns.Write(body, 0, body.Length);
        ns.Flush();
    }
    static void Text(NetworkStream ns, int code, string type, string s) { Send(ns, code, type, Encoding.UTF8.GetBytes(s ?? ""), null); }

    static void Route(NetworkStream ns, Req r) {
 string p = r.Path;
 if (p == "/" || p == "/index.html") { Text(ns, 200, "text/html; charset=utf-8", Html); return; }
 if (p == "/favicon.ico") { Send(ns, 204, "image/x-icon", null, null); return; }
        string k; r.Q.TryGetValue("k", out k);
        if (k != Key) { Text(ns, 403, JS, "{\"error\":\"key\"}"); return; }
        if (p == "/api/jobs") { Text(ns, 200, JS, JobsJson()); return; }
        if (p == "/api/add" && r.Method == "POST") { Add(ns, r); return; }
 if (p == "/api/cancel" && r.Method == "POST") { string id; r.Q.TryGetValue("id", out id); Cancel(id); Text(ns, 200, JS, "{\"ok\":true}"); return; }
        if (p.StartsWith("/f/")) { SendFile(ns, r, p.Substring(3)); return; }
        Text(ns, 404, "text/plain; charset=utf-8", "Not found");
    }

    // ---------- API ----------
    static MsJob FindJob(string id) {
        if (string.IsNullOrEmpty(id)) return null;
 lock (lk) { foreach (MsJob j in jobs) if (j.Id == id) return j; }
        return null;
    }

    static void Add(NetworkStream ns, Req r) {
 Dictionary<string, object> d = null;
        try { d = new JavaScriptSerializer().DeserializeObject(r.Body) as Dictionary<string, object>; } catch { }
 string raw = (d != null && d.ContainsKey("url")) ? Convert.ToString(d["url"]) : "";
 // Accepte aussi un texte de partage (TikTok, Instagram…) : on extrait le premier lien
        Match m = Regex.Match(raw ?? "", "https?://[^\\s<>\"']+", RegexOptions.IgnoreCase);
        if (!m.Success) { Text(ns, 400, JS, "{\"error\":\"url\"}"); return; }
 string kind = (d.ContainsKey("kind") && Convert.ToString(d["kind"]) == "audio") ? "audio" : "video";
 string fmt = d.ContainsKey("fmt") ? Convert.ToString(d["fmt"]) : "";
 if (!Args.ContainsKey(kind + ":" + fmt)) fmt = kind == "audio" ? "mp3" : "1080";
 MsJob j = new MsJob();
        j.Id = Guid.NewGuid().ToString("N").Substring(0, 10);
 j.Url = m.Value.TrimEnd('.', ',', ';', ')');
        j.Kind = kind; j.Fmt = fmt;
 lock (lk) jobs.Add(j);
        Text(ns, 200, JS, "{\"id\":\"" + j.Id + "\"}");
    }

    static void Cancel(string id) {
 MsJob j = FindJob(id);
        if (j == null) return;
 Process p = null; bool removed = false;
 lock (lk) {
     if (j.State == "run") { j.State = "cancel"; p = j.P; }
     else if (j.State == "queued") { j.State = "cancel"; }
     else if (j.Active == 0 && j.P == null) { jobs.Remove(j); removed = true; }
 }
        if (p != null) KillTree(p);
 if (removed) DelDir(j.Dir);
    }

    static string JobsJson() {
 List<object> list = new List<object>();
 lock (lk) {
     for (int i = jobs.Count - 1; i >= 0; i--) {
         MsJob j = jobs[i];
         Dictionary<string, object> o = new Dictionary<string, object>();
  o["id"] = j.Id; o["state"] = j.State; o["url"] = j.Url; o["kind"] = j.Kind; o["fmt"] = j.Fmt;
         o["title"] = j.Title; o["thumb"] = j.Thumb; o["site"] = j.Site;
  o["dl"] = j.Dl; o["tot"] = j.Tot; o["spd"] = j.Spd; o["eta"] = j.Eta; o["stage"] = j.Stage;
  string nm = "";
  try { if (j.FilePath.Length > 0) nm = Path.GetFileName(j.FilePath); } catch { }
         o["name"] = nm; o["size"] = j.Size; o["err"] = j.Err; o["sending"] = j.Active > 0;
  list.Add(o);
     }
        }
 Dictionary<string, object> res = new Dictionary<string, object>();
 res["jobs"] = list; res["pc"] = Pc; res["ver"] = Ver;
        return new JavaScriptSerializer().Serialize(res);
    }

    static string Mime(string ext) {
 switch ((ext ?? "").ToLowerInvariant()) {
     case ".mp4": return "video/mp4";
     case ".m4a": return "audio/mp4";
     case ".mp3": return "audio/mpeg";
     case ".webm": return "video/webm";
     case ".mkv": return "video/x-matroska";
     case ".opus": case ".ogg": return "audio/ogg";
     case ".flac": return "audio/flac";
     case ".wav": return "audio/wav";
     default: return "application/octet-stream";
 }
    }

    static void SendFile(NetworkStream ns, Req r, string id) {
 MsJob j = FindJob(id);
        string f = null;
        lock (lk) {
     if (j != null && (j.State == "done" || j.State == "sent") && File.Exists(j.FilePath)) { f = j.FilePath; j.Active++; }
        }
        if (f == null) { Text(ns, 404, "text/plain; charset=utf-8", "Not found"); return; }
 bool full = false;
 try {
            FileInfo fi = new FileInfo(f);
     long len = fi.Length, a = 0, b = len - 1;
     bool part = false;
     string rg;
     if (r.H.TryGetValue("Range", out rg)) {
         Match m = Regex.Match(rg, "bytes=(\\d*)-(\\d*)");
         if (m.Success) {
      if (m.Groups[1].Value.Length > 0) {
   a = long.Parse(m.Groups[1].Value);
          if (m.Groups[2].Value.Length > 0) b = Math.Min(len - 1, long.Parse(m.Groups[2].Value));
      } else if (m.Groups[2].Value.Length > 0) {
          a = Math.Max(0, len - long.Parse(m.Groups[2].Value));
      }
      part = true;
      if (a > b || a >= len) { Send(ns, 416, "text/plain", null, "Content-Range: bytes */" + len + "\r\n"); return; }
  }
     }
     string name = fi.Name;
     StringBuilder sa = new StringBuilder();
     foreach (char ch in name) sa.Append((ch < 32 || ch > 126 || ch == '"' || ch == '\\') ? '_' : ch);
     long cnt = b - a + 1;
     string h = "HTTP/1.1 " + (part ? "206 Partial Content" : "200 OK")
       + "\r\nContent-Type: " + Mime(fi.Extension)
       + "\r\nContent-Length: " + cnt
       + "\r\nAccept-Ranges: bytes\r\n"
+ (part ? "Content-Range: bytes " + a + "-" + b + "/" + len + "\r\n" : "")
       + "Content-Disposition: attachment; filename=\"" + sa.ToString() + "\"; filename*=UTF-8''" + Uri.EscapeDataString(name)
+ "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
     byte[] hb = Encoding.ASCII.GetBytes(h);
     ns.Write(hb, 0, hb.Length);
     if (r.Method == "HEAD") return;
     Note = name;
     using (FileStream fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
  fs.Seek(a, SeekOrigin.Begin);
         byte[] buf = new byte[262144];
         long left = cnt;
         while (left > 0) {
      int n = fs.Read(buf, 0, (int)Math.Min(buf.Length, left));
      if (n <= 0) break;
      ns.Write(buf, 0, n);
      left -= n;
  }
         ns.Flush();
  full = left == 0 && b == len - 1;
     }
        } finally {
            lock (lk) {
  j.Active--;
  if (full) { j.LastSend = DateTime.Now; j.State = "sent"; Sent++; }
         if (j.Active <= 0) Note = "";
            }
        }
    }

    // ---------- téléchargements ----------
    static string Q(string s) {
        if (s == null) s = "";
        if (s.Length > 0 && s.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return s;
        StringBuilder sb = new StringBuilder("\"");
        int bs = 0;
        foreach (char c in s) {
     if (c == '\\') { bs++; continue; }
            if (c == '"') { sb.Append('\\', bs * 2 + 1); sb.Append('"'); bs = 0; continue; }
            if (bs > 0) { sb.Append('\\', bs); bs = 0; }
     sb.Append(c);
        }
        if (bs > 0) sb.Append('\\', bs * 2);
 sb.Append('"');
        return sb.ToString();
    }

    static double Num(string s) {
        double d;
        return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out d) ? d : -1;
    }

    static void Line(MsJob j, string l) {
        lock (lk) {
            if (l.StartsWith("MSP|")) {
         string[] f = l.Split('|');
         if (f.Length < 6) return;
  double d = Num(f[1]), t = Num(f[2]);
         if (t <= 0) t = Num(f[3]);
  if (d >= 0 && j.Prev > 1048576 && d < j.Prev * 0.5) j.Stage++;
         if (d >= 0) j.Prev = d;
  j.Dl = d; j.Tot = t; j.Spd = Num(f[4]); j.Eta = Num(f[5]);
     } else if (l.StartsWith("MST|")) {
  string[] f = l.Split(new char[] { '|' }, 4);
  if (f.Length >= 4) {
      if (f[1] != "NA") j.Site = f[1];
      if (f[2].StartsWith("http")) j.Thumb = f[2];
      if (f[3] != "NA") j.Title = f[3];
         }
     } else if (l.StartsWith("MSF|")) {
  j.FilePath = l.Substring(4).Trim();
     } else if (l.StartsWith("ERROR")) {
  string e = Regex.Replace(l, "^ERROR:\\s*", "");
  j.Err = e.Length > 220 ? e.Substring(0, 220) + "…" : e;
     }
 }
    }

    static string Biggest(string d) {
        string best = ""; long bl = -1;
        try { foreach (string f in Directory.GetFiles(d)) { long l = new FileInfo(f).Length; if (l > bl) { bl = l; best = f; } } } catch { }
        return best;
    }

    static void KillTree(Process p) {
        try {
     ProcessStartInfo k = new ProcessStartInfo("taskkill.exe", "/PID " + p.Id + " /T /F");
     k.CreateNoWindow = true; k.UseShellExecute = false;
            Process.Start(k).WaitForExit(5000);
        } catch { }
    }

    static void DelDir(string d) {
        if (string.IsNullOrEmpty(d)) return;
        for (int i = 0; i < 6; i++) {
     try { if (Directory.Exists(d)) Directory.Delete(d, true); return; }
     catch { Thread.Sleep(300); }
        }
    }

    static void Sweep() {
 List<MsJob> del = new List<MsJob>();
        lock (lk) {
     foreach (MsJob j in jobs)
         if (j.State == "sent" && j.Active == 0 && (DateTime.Now - j.LastSend).TotalSeconds > 180) { j.State = "gone"; del.Add(j); }
 }
        foreach (MsJob j in del) DelDir(j.Dir);
    }

    static void WorkLoop(int g) {
        while (running && g == gen) {
     MsJob next = null;
     lock (lk) {
         foreach (MsJob j in jobs) { if (j.State == "queued") { next = j; break; } }
  if (next != null) next.State = "run";
            }
     if (next != null) { Run(next); continue; }
     Sweep();
     Thread.Sleep(250);
 }
    }

    static void Run(MsJob j) {
        Process p = null;
        try {
     j.Dir = Path.Combine(Root, "w_" + j.Id);
     Directory.CreateDirectory(j.Dir);
            string extra;
     if (!Args.TryGetValue(j.Kind + ":" + j.Fmt, out extra)) extra = "";
            StringBuilder a = new StringBuilder();
     a.Append("--newline --no-colors --progress --no-warnings --ignore-config --no-mtime --no-playlist");
            a.Append(" -P ").Append(Q("home:" + j.Dir));
     a.Append(" -P ").Append(Q("temp:" + Path.Combine(j.Dir, "part")));
     a.Append(" -o ").Append(Q("%(title).120B.%(ext)s"));
     a.Append(" --progress-template ").Append(Q("download:MSP|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s"));
     a.Append(" --print ").Append(Q("before_dl:MST|%(extractor_key)s|%(thumbnail)s|%(title)s"));
     a.Append(" --print ").Append(Q("after_move:MSF|%(filepath)s"));
     a.Append(" --no-simulate");
     if (!string.IsNullOrEmpty(FfDir)) a.Append(" --ffmpeg-location ").Append(Q(FfDir));
     if (extra.Length > 0) a.Append(' ').Append(extra);
     a.Append(" -- ").Append(Q(j.Url));

     ProcessStartInfo psi = new ProcessStartInfo(Yt, a.ToString());
            psi.UseShellExecute = false; psi.CreateNoWindow = true;
     psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
     psi.StandardOutputEncoding = Encoding.UTF8; psi.StandardErrorEncoding = Encoding.UTF8;
     psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
     psi.EnvironmentVariables["PYTHONUTF8"] = "1";
     p = new Process();
     p.StartInfo = psi;
     MsJob jj = j;
     p.OutputDataReceived += (s, e) => { if (e.Data != null) Line(jj, e.Data); };
     p.ErrorDataReceived += (s, e) => { if (e.Data != null) Line(jj, e.Data); };

     bool go;
     lock (lk) go = j.State == "run";
     if (go) {
         p.Start();
         bool kill;
         lock (lk) { j.P = p; kill = j.State != "run"; }
         if (kill) KillTree(p);
  p.BeginOutputReadLine();
  p.BeginErrorReadLine();
  p.WaitForExit();
         int code = p.ExitCode;
         lock (lk) {
      j.P = null;
      if (j.State == "run") {
   if ((j.FilePath.Length == 0 || !File.Exists(j.FilePath)) && code == 0) j.FilePath = Biggest(j.Dir);
   if (j.FilePath.Length > 0 && File.Exists(j.FilePath)) { j.Size = new FileInfo(j.FilePath).Length; j.State = "done"; }
          else { j.State = "error"; if (j.Err.Length == 0) j.Err = "yt-dlp : code " + code; }
      }
  }
     }
        } catch (Exception ex) {
     lock (lk) { j.P = null; if (j.State == "run") { j.State = "error"; j.Err = ex.Message; } }
 } finally {
     if (p != null) { try { p.Close(); } catch { } }
        }
        string st;
        lock (lk) st = j.State;
 if (st != "done") DelDir(j.Dir);
    }
}
'@
} catch { $St.WebErr = [string]$_.Exception.Message }

# Arguments yt-dlp pré-calculés pour chaque choix proposé sur la page
function Web-ArgMap {
    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    foreach ($v in @('max', '2160', '1080', '720')) {
        $h = if ($v -eq 'max') { 0 } else { [int]$v }
        $map['video:' + $v] = ((Video-Args $h) | ForEach-Object { QArg $_ }) -join ' '
    }
    foreach ($v in @('mp3', 'm4a', 'best')) { $map['audio:' + $v] = ((Audio-Args $v) | ForEach-Object { QArg $_ }) -join ' ' }
    return ,$map
}

function Draw-WebStatus([int]$tick) {
    $x = $Web.sx; $y = $Web.sy; $wd = [Math]::Max(20, $Web.sw)
    $out = New-Object 'Collections.Generic.List[string]'
    $out.Add($Col.Ok + '●  ' + $Col.Fg + ((L 'w_listen') -f [MsWeb]::Port) + $Col.Dim + '   ·   ' + ((L 'w_stats') -f [MsWeb]::Sent))
    $note = [string][MsWeb]::Note
    if ($note) { $out.Add($Col.Acc + '⇅  ' + $Col.Fg + (Trunc ((L 'w_send') -f $note) ($wd - 4))) }
    elseif ([MsWeb]::PeerAge -lt 6) { $out.Add($Col.Ok + '⇄  ' + $Col.Fg + ((L 'w_conn') -f [MsWeb]::Peer)) }
    else { $out.Add($Col.Dim + '○  ' + (L 'w_noconn')) }
    $out.Add('')
    $rows = @([MsWeb]::Status(4))
    if ($rows.Count -eq 0) { $out.Add($Col.Dim + (Trunc (L 'w_wait') $wd)) }
    foreach ($r in $rows) {
        $f = ([string]$r).Split([char[]]@([char]'|'), 3); $tail = ''
        $ttl = if ($f.Count -ge 3) { $f[2] } else { '' }
        switch ($f[0]) {
     'run'    { $ic = $Col.Acc + $Spin[$tick % $Spin.Count]; $pc = Num $f[1]; if ($pc -ge 0) { $tail = '{0,7:N1} %' -f $pc } }
     'queued' { $ic = $Col.Dim + '·' }
     'done'   { $ic = $Col.Ok + '✔' }
     'sent'   { $ic = $Col.Ok + '⇣' }
     'gone'   { $ic = $Col.Dim + '✔' }
     'error'  { $ic = $Col.Err + '✖' }
     default  { $ic = $Col.Warn + '■' }
 }
        $out.Add($ic + '  ' + $Col.Fg + (Trunc $ttl ($wd - 13)) + $Col.Dim + $tail)
    }
    while ($out.Count -lt 7) { $out.Add('') }
    $out.Add('')
    $out.Add($Col.Dim + (Trunc (L 'w_hint') $wd))
    for ($i = 0; $i -lt $out.Count; $i++) { try { [Console]::SetCursorPosition($x, $y + $i); Wr ($out[$i] + $Rst + $Eol) } catch {} }
}

function Flow-Web {
    if (-not (Ensure-Tools)) { return }
    if (-not ('MsWeb' -as [type])) { Show-Fail (L 'w_fail') ([string]$St.WebErr); return }
    if (-not $Cfg.webkey) {
        $abc = 'abcdefghjkmnpqrstuvwxyz23456789'
        $Cfg.webkey = -join (1..10 | ForEach-Object { $abc[(Get-Random -Maximum $abc.Length)] })
        Save-Cfg
    }
    $base = [int]$Cfg.port; if ($base -lt 1024 -or $base -gt 65000) { $base = 8765 }
    $root = Join-Path $Tmp 'web'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    [MsWeb]::Key   = [string]$Cfg.webkey
    [MsWeb]::Yt    = [string]$St.YT
    [MsWeb]::FfDir = [string]$St.FFDir
    [MsWeb]::Root  = $root
    [MsWeb]::Pc    = [string]$env:COMPUTERNAME
    [MsWeb]::Ver   = [string]$App.Ver
    [MsWeb]::Html  = [string](Web-Page)
    [MsWeb]::Args  = (Web-ArgMap)
    $port = [MsWeb]::Start($base)
    if ($port -le 0) { Show-Fail (L 'w_fail') ([string][MsWeb]::LastError); return }

    try {
        $ip = Get-LanIp
        $url = 'http://' + $ip + ':' + $port + '/?k=' + $Cfg.webkey
        Draw-Header -Compact
        $m = ' ' * $St.M; $w = [Console]::WindowWidth
        $tt = [string](L 'w_title')
        Ln ($m + $Col.Line + '╭─ ' + $Col.Acc + '✦ ' + $Col.Hi + $tt + ' ' + (Fade ([Math]::Max(4, [Math]::Min(80, $w - 2 * $St.M) - (Vis $tt) - 6))))
        Ln ''
        $top = [Console]::CursorTop
        $qr = Qr-Lines $url 2
        $side = ($qr.width -gt 0) -and ($w -ge $St.M + $qr.width + 50)
        $x = if ($side) { $St.M + $qr.width + 4 } else { $St.M }
 $iw = [Math]::Max(20, $w - $x - 2)
        $info = New-Object 'Collections.Generic.List[string]'
        foreach ($pr in @(@($Col.Fg, (L 'w_scan')), @($Col.Acc, $url), @('', ''), @($Col.Dim, (L 'w_same')), @($Col.Dim, (L 'w_fw')))) {
     if (-not $pr[1]) { $info.Add(''); continue }
            foreach ($pc in (Wrap $pr[1] $iw 3)) { $info.Add($pr[0] + $pc) }
        }
 if ($side) {
     $y = $top
     foreach ($ql in $qr.lines) { try { [Console]::SetCursorPosition($St.M, $y) } catch {}; Wr $ql; $y++ }
     $y = $top + 1
     foreach ($il in $info) { try { [Console]::SetCursorPosition($x, $y) } catch {}; Wr ($il + $Rst); $y++ }
     $Web.sy = $y + 1
        } else {
            foreach ($ql in $qr.lines) { Ln ($m + $ql) }
     Ln ''
            foreach ($il in $info) { Ln ($m + $il) }
     Ln ''
     $Web.sy = [Console]::CursorTop
 }
        $Web.sx = $x; $Web.sw = $iw

 # Le serveur tourne sur ses propres threads : cette boucle ne fait qu'afficher
        $last = -1000; $tick = 0; $clk = [Diagnostics.Stopwatch]::StartNew()
        Flush-Keys
        while ($true) {
            $stop = $false
            while ([Console]::KeyAvailable) {
  $k = [Console]::ReadKey($true)
  if ($k.Key -eq 'Escape') { $stop = $true }
         elseif ($k.Key -eq 'Enter') { Start-Process ('http://127.0.0.1:' + $port + '/?k=' + $Cfg.webkey) }
     }
     if ($stop) { break }
     if ($clk.ElapsedMilliseconds - $last -ge 200) { $last = $clk.ElapsedMilliseconds; $tick++; Draw-WebStatus $tick }
     Start-Sleep -Milliseconds 40
 }
    } finally {
 [MsWeb]::Stop()
        Clean-Tmp
    }
}

# ---------------------------------------------------------------------
#  Paramètres & outils
# ---------------------------------------------------------------------
function Pick-Folder {
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = L 'pick'; $dlg.SelectedPath = $Cfg.out; $dlg.ShowNewFolderButton = $true
    $owner = New-Object Windows.Forms.Form; $owner.TopMost = $true
    if ($dlg.ShowDialog($owner) -eq [Windows.Forms.DialogResult]::OK) { $Cfg.out = $dlg.SelectedPath }
    $owner.Dispose(); $dlg.Dispose()
}

function Flow-Settings {
    $sel = 0
    while ($true) {
        $items = @(
            (Kv (L 's_lang')   $Langs[[string]$Cfg.lang]),
     (Kv (L 's_folder') (Trunc $Cfg.out 42)),
     (Kv (L 's_vq')     (VqLabel $Cfg.vq)),
     (Kv (L 's_af')     (AfLabel $Cfg.af)),
     (Kv (L 's_thumb')  (OnOff $Cfg.thumb)),
     (Kv (L 's_pl')     (OnOff $Cfg.playlist)),
     (Kv (L 's_cover')  (OnOff $Cfg.cover)),
     ('⇄  ' + (L 's_web')),
     ('▣  ' + (L 's_notice')),
     (L 'back')
        )
 $c = Menu (L 'm_settings') $items $sel
 if ($c -lt 0 -or $c -eq 9) { return }
        $sel = $c
        switch ($c) {
     0 { $keys = @($Langs.Keys); $i = Menu (L 's_lang') @($Langs.Values) ([Array]::IndexOf($keys, [string]$Cfg.lang)); if ($i -ge 0) { $Cfg.lang = $keys[$i] } }
     1 { Pick-Folder }
            2 { $vk = @('max', '2160', '1440', '1080', '720', '480'); $i = Menu (L 's_vq') @($vk | ForEach-Object { VqLabel $_ }) ([Array]::IndexOf($vk, [string]$Cfg.vq)); if ($i -ge 0) { $Cfg.vq = $vk[$i] } }
     3 { $ak = @('best', 'mp3', 'wav', 'flac', 'm4a'); $i = Menu (L 's_af') @($ak | ForEach-Object { L "a_$_" }) ([Array]::IndexOf($ak, [string]$Cfg.af)); if ($i -ge 0) { $Cfg.af = $ak[$i] } }
     4 { $Cfg.thumb = -not $Cfg.thumb }
            5 { $Cfg.playlist = -not $Cfg.playlist }
     6 { $Cfg.cover = -not $Cfg.cover }
     7 { Flow-Web }
     8 { Show-Notice }
        }
        Save-Cfg
    }
}

function Flow-Tools {
    $sel = 0
    while ($true) {
        $c = Menu (L 'm_tools') @((L 't_yt'), (L 't_ff'), (L 't_up'), (L 'back')) $sel
 if ($c -lt 0 -or $c -eq 3) { return }
        $sel = $c
        switch ($c) { 0 { Install-Tools @('yt-dlp') } 1 { Install-Tools @('ffmpeg') } 2 { Update-Yt } }
    }
}

function Say-Bye {
    Draw-Header
    $msg = L 'bye'; $w = [Console]::WindowWidth
    Ln ((' ' * [Math]::Max(0, [int](($w - $msg.Length) / 2))) + $Col.Acc + $msg)
    Ln ''
    Start-Sleep -Milliseconds 900
    Wr $Rst
    try { [Console]::CursorVisible = $true } catch {}
}

# ---------------------------------------------------------------------
#  Démarrage
# ---------------------------------------------------------------------
try {
    Load-Cfg
    if (-not $Cfg.lang -or -not $Langs.Contains([string]$Cfg.lang)) {
 $c0 = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
        $Cfg.lang = if ($Langs.Contains($c0)) { $c0 } else { 'en' }
        Save-Cfg
    }
    [void][MsNative]::EnableVT()
    try { [Console]::CursorVisible = $false } catch {}
    Clean-Tmp
    Refresh-Tools
    if (-not ($St.YT -and $St.FF)) { [void](Ensure-Tools) }

    $mainSel = 0
    while ($true) {
 $items = @((L 'm_dl'), (L 'm_queue'), (L 'm_settings'), (L 'm_tools'), (L 'm_open'), (L 'm_quit'))
        $choice = Menu (L 'menu') $items $mainSel
        if ($choice -ge 0) { $mainSel = $choice }
 switch ($choice) {
     0 { Flow-Single }
     1 { Flow-Queue }
     2 { Flow-Settings }
     3 { Flow-Tools }
     4 { if (-not (Test-Path $Cfg.out)) { New-Item -ItemType Directory -Force -Path $Cfg.out | Out-Null }; Start-Process explorer.exe $Cfg.out }
     default { Say-Bye; Clean-Tmp; exit }
        }
    }
} catch {
    try { [Console]::CursorVisible = $true } catch {}
    Write-Host ''
    Write-Host ('Erreur : ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    Read-Host 'Entrée pour quitter'
}