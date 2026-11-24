#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  ✦ MAELSTRÖM v6.2 — Linux
#  Téléchargeur universel (yt-dlp + ffmpeg) · interface terminal + mode web
#  100 % bash : aucun Python. Le mode web utilise socat (ou ncat).
#
#  Lancement :  chmod +x maelstrom.sh && ./maelstrom.sh
#  Direct    :  ./maelstrom.sh URL [URL…]
# ─────────────────────────────────────────────────────────────────────

if [ -z "${BASH_VERSION:-}" ]; then echo "Lancez ce script avec bash : bash maelstrom.sh"; exit 1; fi
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  echo "Bash 4.3 ou plus récent est requis."; exit 1
fi
shopt -s extglob
case "$(locale charmap 2>/dev/null)" in UTF-8|utf8) ;; *) export LC_ALL=C.UTF-8 ;; esac

VERSION="6.2"
SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/maelstrom"
CONF="$CONF_DIR/config"
HIST="$CONF_DIR/historique.log"
TOOLS="${XDG_DATA_HOME:-$HOME/.local/share}/maelstrom/bin"
mkdir -p "$CONF_DIR" "$TOOLS" 2>/dev/null
export PATH="$TOOLS:$HOME/.deno/bin:$HOME/.local/bin:$PATH"
export NO_COLOR=1
WORK="${MS_WORK:-}"
SRV_PID=""
COLS=80

# ── Palette chaude ───────────────────────────────────────────────────
R=$'\e[0m'; B=$'\e[1m'
C_ACC=$'\e[38;2;240;150;90m'
C_TXT=$'\e[38;2;236;226;212m'
C_DIM=$'\e[38;2;150;136;122m'
C_LINE=$'\e[38;2;88;70;56m'
C_OK=$'\e[38;2;150;200;130m'
C_ERR=$'\e[38;2;235;110;100m'
C_WARN=$'\e[38;2;240;200;110m'

# ── Réglages ─────────────────────────────────────────────────────────
DL_DIR=""; FMT_MODE=video; FMT_Q=1080; FMT_A=mp3; PARALLEL=3
PLAYLIST=0; SUBS=0; SPONSOR=0; EMBED=1; COOKIES=""; PORT=8765

have() { command -v "$1" >/dev/null 2>&1; }

default_dir() {
  local d=""
  have xdg-user-dir && d=$(xdg-user-dir DOWNLOAD 2>/dev/null)
  [[ -z $d || $d == "$HOME" ]] && d="$HOME/Downloads"
  printf '%s' "$d"
}

load_config() {
  [[ -f $CONF ]] && source "$CONF"
  [[ -z $DL_DIR ]] && DL_DIR=$(default_dir)
  [[ $PARALLEL =~ ^[1-5]$ ]] || PARALLEL=3
  [[ $PORT =~ ^[0-9]+$ ]] || PORT=8765
  [[ $FMT_MODE == audio ]] || FMT_MODE=video
}

save_config() {
  local k
  for k in DL_DIR FMT_MODE FMT_Q FMT_A PARALLEL PLAYLIST SUBS SPONSOR EMBED COOKIES PORT; do
    printf '%s=%q\n' "$k" "${!k}"
  done >"$CONF"
}

# ── Petits outils d'affichage ────────────────────────────────────────
rep() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }
cur_off() { printf '\e[?25l'; }
cur_on() { printf '\e[?25h'; }
term_cols() { local r c; read -r r c < <(stty size 2>/dev/null); [[ $c =~ ^[0-9]+$ ]] || c=80; COLS=$c; }
trunc() { local s=$1 w=$2; (( w < 8 )) && w=8; (( ${#s} > w )) && s="${s:0:w-1}…"; printf '%s' "$s"; }
short_path() { local p=$1; [[ $p == "$HOME"* ]] && p="~${p#"$HOME"}"; printf '%s' "$p"; }
yn() { (( $1 )) && printf 'oui' || printf 'non'; }

grad() {
  local s=$1 n=${#1} i d r g b out=""
  d=$(( n > 1 ? n - 1 : 1 ))
  for (( i = 0; i < n; i++ )); do
    r=$(( 245 - 13 * i / d )); g=$(( 160 - 52 * i / d )); b=$(( 92 + 6 * i / d ))
    out+=$'\e[38;2;'"${r};${g};${b}m${s:i:1}"
  done
  printf '%s%s' "$out" "$R"
}

dot() {
  if have "$1"; then printf '%s%s %s●%s' "$C_TXT" "$1" "$C_OK" "$R"
  else printf '%s%s %s●%s' "$C_DIM" "$1" "$C_ERR" "$R"; fi
}

hdr() {
  term_cols
  printf '\e[H\e[2J\e[3J\n'
  printf '  %s%s%s\e[31G%s│%s  %sv%s · Linux%s\n' "$B" "$(grad '✦ M A E L S T R Ö M')" "$R" "$C_LINE" "$R" "$C_DIM" "$VERSION" "$R"
  printf '  %s  %s  %s\e[31G%s│%s  %s%s%s\n' "$(dot yt-dlp)" "$(dot ffmpeg)" "$(dot deno)" "$C_LINE" "$R" "$C_TXT" "$(short_path "$DL_DIR")" "$R"
  local w=$(( COLS - 4 )); (( w > 72 )) && w=72
  printf '  %s%s%s\n' "$C_LINE" "$(rep '─' "$w")" "$R"
}

section()  { printf '\n  %s%s%s  %s%s%s%s\n\n' "$C_ACC" "$1" "$R" "$B" "$C_TXT" "$2" "$R"; }
say_ok()   { printf '  %s✓%s %s\n' "$C_OK" "$R" "$*"; }
say_err()  { printf '  %s✗ %s%s\n' "$C_ERR" "$*" "$R"; }
say_warn() { printf '  %s!%s %s\n' "$C_WARN" "$R" "$*"; }
say_dim()  { printf '  %s%s%s\n' "$C_DIM" "$*" "$R"; }
step()     { printf '  %s›%s %s\n' "$C_ACC" "$R" "$*"; }

drain() { local x; while IFS= read -rsn1 -t 0.01 x; do :; done; }
pause() { drain; cur_on; printf '\n  %sAppuyez sur une touche…%s' "$C_DIM" "$R"; IFS= read -rsn1 _; printf '\n'; drain; }

read_key() {
  local c="" s=""
  IFS= read -rsn1 c
  if [[ $c == $'\e' ]]; then
    IFS= read -rsn2 -t 0.05 s
    case $s in
      '[A'|'OA') KEY=UP ;;   '[B'|'OB') KEY=DOWN ;;
      '[C'|'OC') KEY=RIGHT ;; '[D'|'OD') KEY=LEFT ;;
      '') KEY=ESC ;;
      *) KEY=OTHER; drain ;;
    esac
  elif [[ -z $c ]]; then KEY=ENTER
  else KEY=$c; fi
}

# menu <sélection par défaut> <entrées…>  →  REPLY_IDX (-1 = Échap)
menu() {
  local sel=${1:-0}; shift
  local -a it=("$@"); local n=${#it[@]} i
  (( sel >= n || sel < 0 )) && sel=0
  cur_off
  while :; do
    for (( i = 0; i < n; i++ )); do
      if (( i == sel )); then printf '\e[2K  %s❯%s %s%s%s%s\n' "$C_ACC" "$R" "$B" "$C_TXT" "${it[i]}" "$R"
      else printf '\e[2K    %s%s%s\n' "$C_DIM" "${it[i]}" "$R"; fi
    done
    printf '\e[2K\n\e[2K  %s↑↓ naviguer · Entrée valider · Échap retour%s' "$C_LINE" "$R"
    read_key
    case $KEY in
      UP|k)        sel=$(( (sel - 1 + n) % n )) ;;
      DOWN|j)      sel=$(( (sel + 1) % n )) ;;
      ENTER|RIGHT) REPLY_IDX=$sel; break ;;
      ESC|LEFT)    REPLY_IDX=-1; break ;;
      [1-9])       if (( KEY <= n )); then REPLY_IDX=$(( KEY - 1 )); break; fi ;;
    esac
    printf '\r\e[%dA' $(( n + 1 ))
  done
  printf '\n'
  cur_on
}

ask() {
  printf '  %s%s%s\n' "$C_TXT" "$1" "$R"
  cur_on
  IFS= read -r -e -p "  › " -i "${2:-}" ANSWER
}

open_path() {
  if have xdg-open; then xdg-open "$1" >/dev/null 2>&1 & disown
  else say_warn "xdg-open introuvable."; pause; fi
}

kill_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill "$1" 2>/dev/null; }

# ── Installation des outils (sans Python, sans sudo quand c'est possible) ──
cpu_arch() {
  case $(uname -m) in
    x86_64|amd64) echo x64 ;; aarch64|arm64) echo arm64 ;;
    armv7*|armhf) echo armv7 ;; *) echo other ;;
  esac
}

fetch() {
  if have curl; then curl -fL --retry 2 --connect-timeout 15 --progress-bar -o "$2" "$1"
  elif have wget; then wget -q --show-progress -O "$2" "$1"
  else say_err "Ni curl ni wget n'est installé."; return 1; fi
}

pkg_install() {
  step "Gestionnaire de paquets : $*  (mot de passe sudo possible)"
  local S=""; (( EUID != 0 )) && S=sudo
  if   have apt-get;      then $S apt-get update -qq && $S apt-get install -y "$@"
  elif have dnf;   then $S dnf install -y "$@"
  elif have pacman;       then $S pacman -S --needed --noconfirm "$@"
  elif have zypper;then $S zypper --non-interactive install "$@"
  elif have apk;          then $S apk add "$@"
  elif have xbps-install; then $S xbps-install -Sy "$@"
  else say_err "Gestionnaire de paquets non reconnu : installez $* à la main."; return 1; fi
  hash -r
}

install_ytdlp() {
  local a
  case $(cpu_arch) in
    x64) a=yt-dlp_linux ;; arm64) a=yt-dlp_linux_aarch64 ;; armv7) a=yt-dlp_linux_armv7l ;;
    *) pkg_install yt-dlp; return ;;
  esac
  step "yt-dlp : binaire autonome (sans Python)…"
  if fetch "https://github.com/yt-dlp/yt-dlp/releases/latest/download/$a" "$TOOLS/yt-dlp.part"; then
    chmod +x "$TOOLS/yt-dlp.part" && mv -f "$TOOLS/yt-dlp.part" "$TOOLS/yt-dlp"; hash -r
    say_ok "yt-dlp $("$TOOLS/yt-dlp" --version 2>/dev/null) installé"
  else
    rm -f "$TOOLS/yt-dlp.part"; say_err "Échec du téléchargement de yt-dlp."; return 1
  fi
}

update_ytdlp() {
  if [[ $(command -v yt-dlp) == "$TOOLS/yt-dlp" ]]; then
    step "Mise à jour de yt-dlp…"; yt-dlp -U 2>&1 | sed 's/^/    /'
  else
    say_dim "La version actuelle vient du système : installation d'une copie autonome à jour."
    install_ytdlp
  fi
}

install_ffmpeg() {
  local a
  case $(cpu_arch) in x64) a=linux64 ;; arm64) a=linuxarm64 ;; *) pkg_install ffmpeg; return ;; esac
  step "ffmpeg : version statique (yt-dlp/FFmpeg-Builds, ~100 Mo)…"
  local t="$WORK/ffmpeg.tar.xz" x="$WORK/ffx" f
  if fetch "https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-$a-gpl.tar.xz" "$t"; then
    step "Extraction…"; mkdir -p "$x"
    if tar -xJf "$t" -C "$x" 2>/dev/null; then
      for f in ffmpeg ffprobe; do
        find "$x" -type f -name "$f" -exec mv -f {} "$TOOLS/$f" \;
        chmod +x "$TOOLS/$f" 2>/dev/null
      done
      rm -rf "$x" "$t"; hash -r
      have ffmpeg && { say_ok "ffmpeg installé"; return 0; }
    fi
  fi
  rm -rf "$x" "$t"
  say_warn "Version statique indisponible, essai via le gestionnaire de paquets…"
  pkg_install ffmpeg
}

install_deno() {
  local a
  case $(cpu_arch) in x64) a=x86_64 ;; arm64) a=aarch64 ;; *) say_err "Deno n'existe pas pour cette architecture."; return 1 ;; esac
  have unzip || pkg_install unzip || { say_err "unzip est nécessaire pour installer Deno."; return 1; }
  step "Deno : moteur JavaScript utilisé par yt-dlp pour YouTube…"
  local z="$WORK/deno.zip"
  if fetch "https://github.com/denoland/deno/releases/latest/download/deno-$a-unknown-linux-gnu.zip" "$z" \
     && unzip -o -q "$z" -d "$TOOLS"; then
    chmod +x "$TOOLS/deno"; rm -f "$z"; hash -r
    say_ok "Deno $(deno --version 2>/dev/null | awk 'NR==1{print $2}') installé"
  else
    rm -f "$z"; say_err "Échec de l'installation de Deno."; return 1
  fi
}

install_tool() {
  case $1 in
    yt-dlp) install_ytdlp ;; ffmpeg) install_ffmpeg ;; deno) install_deno ;;
    socat|chafa|qrencode) pkg_install "$1" ;;
  esac
}

tool_ver() {
  case $1 in
    yt-dlp)   yt-dlp --version 2>/dev/null ;;
    ffmpeg)   ffmpeg -version 2>/dev/null | awk 'NR==1{print $3}' ;;
    deno)     deno --version 2>/dev/null | awk 'NR==1{print $2}' ;;
    socat)    socat -V 2>/dev/null | awk '/socat version/{print $3; exit}' ;;
    chafa)    chafa --version 2>/dev/null | awk 'NR==1{print $3}' ;;
    qrencode) qrencode --version 2>&1 | awk 'NR==1{print $3}' ;;
  esac
}

# Pré-téléchargement : tout ce qui manque au premier lancement, socat compris
first_check() {
  local -a miss=(); local t
  have yt-dlp || miss+=(yt-dlp)
  have ffmpeg || miss+=(ffmpeg)
  have deno   || miss+=(deno)
  have socat || have ncat || miss+=(socat)
  (( ${#miss[@]} )) || return 0
  hdr; section "⚙" "Préparation des outils"
  say_dim "Il manque : ${miss[*]}"
  say_dim "yt-dlp, ffmpeg et Deno vont dans ~/.local/share/maelstrom/bin (sans sudo)."
  say_dim "socat (pour le mode web) passe par le gestionnaire de paquets."
  printf '\n'
  menu 0 "Tout installer maintenant (recommandé)" "Plus tard"
  (( REPLY_IDX == 0 )) || return 0
  printf '\n'
  for t in "${miss[@]}"; do install_tool "$t"; done
  pause
}

# ── Format et arguments yt-dlp ───────────────────────────────────────
fmt_label() {
  if [[ $FMT_MODE == audio ]]; then FMT_LABEL="Audio ${FMT_A^^}"
  else
    case $FMT_Q in
      best) FMT_LABEL="Vidéo MP4 · qualité max" ;;
      2160) FMT_LABEL="Vidéo MP4 · 2160p (4K)" ;;
      1080) FMT_LABEL="Vidéo MP4 · 1080p (Full HD)" ;;
      *)    FMT_LABEL="Vidéo MP4 · ${FMT_Q}p" ;;
    esac
  fi
}

build_args() {
  fmt_label
  COOKIE_ARGS=(); [[ -n $COOKIES ]] && COOKIE_ARGS=(--cookies-from-browser "$COOKIES")
  YDL_ARGS=(--no-colors --newline --progress --no-simulate -N 4
    --progress-template 'download:@@P %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s'
    --print 'before_dl:@@T %(title)s'
    --print 'after_move:@@F %(filepath)s'
    -P "$DL_DIR" -o '%(playlist_index&{:03d} - |)s%(title).180B.%(ext)s'
    --embed-metadata "${COOKIE_ARGS[@]}")
  if (( PLAYLIST )); then YDL_ARGS+=(--yes-playlist); else YDL_ARGS+=(--no-playlist); fi
  if [[ $FMT_MODE == audio ]]; then
    YDL_ARGS+=(-f 'ba/b' -x --audio-format "$FMT_A" --audio-quality 0)
    (( EMBED )) && [[ $FMT_A != wav ]] && YDL_ARGS+=(--embed-thumbnail)
  else
    if [[ $FMT_Q == best ]]; then YDL_ARGS+=(-f 'bv*+ba/b' -S 'res,vcodec:h264,acodec:aac')
    else YDL_ARGS+=(-f 'bv*+ba/b' -S "res:$FMT_Q,vcodec:h264,acodec:aac"); fi
    YDL_ARGS+=(--merge-output-format mp4)
    (( EMBED )) && YDL_ARGS+=(--embed-thumbnail)
    (( SUBS )) && YDL_ARGS+=(--write-subs --sub-langs 'fr.*,en.*' --embed-subs)
  fi
  (( SPONSOR )) && YDL_ARGS+=(--sponsorblock-remove sponsor)
}

idx_of() { local v=$1 i=0; shift; for x in "$@"; do [[ $x == "$v" ]] && { echo "$i"; return; }; (( i++ )); done; echo 0; }

choose_format() {
  hdr; section "◈" "Format"
  local d=0; [[ $FMT_MODE == audio ]] && d=1
  menu "$d" "▶  Vidéo MP4" "♪  Audio seulement"
  (( REPLY_IDX < 0 )) && return 1
  if (( REPLY_IDX == 0 )); then
    local -a v=(best 2160 1440 1080 720 480 360)
    local -a l=("Meilleure qualité disponible" "2160p · 4K" "1440p · 2K" "1080p · Full HD" "720p · HD" "480p" "360p")
    hdr; section "▶" "Qualité vidéo"
    menu "$(idx_of "$FMT_Q" "${v[@]}")" "${l[@]}"
    (( REPLY_IDX < 0 )) && return 1
    FMT_MODE=video; FMT_Q=${v[REPLY_IDX]}
  else
    local -a v=(mp3 m4a opus flac wav)
    local -a l=("MP3 · universel" "M4A · AAC, idéal Apple" "OPUS · meilleur rapport taille/qualité" "FLAC · sans perte" "WAV · non compressé")
    hdr; section "♪" "Format audio"
    menu "$(idx_of "$FMT_A" "${v[@]}")" "${l[@]}"
    (( REPLY_IDX < 0 )) && return 1
    FMT_MODE=audio; FMT_A=${v[REPLY_IDX]}
  fi
  save_config
}

# ── Moteur de téléchargement (utilisé par le terminal ET le mode web) ──
hist_add() { printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$(date '+%d/%m %H:%M')" "$1" "$FMT_LABEL" "$2" "$3" >>"$HIST"; }

# run_job <dossier de suivi> <url> : 3 essais, avec contournements en cas de 403
run_job() {
  local d=$1 url=$2 a title file msg
  local -a extra
  for a in 1 2 3; do
    case $a in
      1) extra=() ;;
      2) extra=(-4 --rm-cache-dir) ;;
      3) extra=(-4 --extractor-args 'youtube:player_client=tv,web_safari,mweb') ;;
    esac
    printf '%s' "$a" >"$d/try"
    if yt-dlp "${YDL_ARGS[@]}" "${extra[@]}" -- "$url" >"$d/log" 2>&1; then
      title=$(grep -a '^@@T ' "$d/log" | tail -n1); title=${title#@@T }
      file=$(grep -a '^@@F ' "$d/log" | tail -n1); file=${file#@@F }
      hist_add ok "${title:-$url}" "${file:-$url}"
      printf 'ok\n' >"$d/st"
      return 0
    fi
    grep -qaiE 'HTTP Error 403|Forbidden|Sign in to confirm|nsig|challenge|Requested format is not available' "$d/log" || break
  done
  msg=$(grep -a '^ERROR' "$d/log" | tail -n1)
  [[ -z $msg ]] && msg=$(grep -av '^@@' "$d/log" | tail -n1)
  title=$(grep -a '^@@T ' "$d/log" | tail -n1); title=${title#@@T }
  hist_add err "${title:-$url}" "$url"
  printf 'err\t%s\n' "${msg:-Erreur inconnue}" >"$d/st"
  return 1
}

job_peek() {
  local d=$1 l p s e
  P_PCT=0; P_SPD=""; P_ETA=""; P_TITLE=""; P_HAVE=""
  [[ -f $d/log ]] || return 0
  l=$(grep -a '^@@T ' "$d/log" | tail -n1); P_TITLE=${l#@@T }
  l=$(grep -a '^@@P ' "$d/log" | tail -n1)
  if [[ -n $l ]]; then
    P_HAVE=1; l=${l#@@P }; l=${l//$'\e'\[*([0-9;])m/}
    IFS='|' read -r p s e <<<"$l"
    p=${p//[!0-9.]/}; p=${p%%.*}; [[ -z $p ]] && p=0
    P_PCT=$(( 10#$p )); (( P_PCT > 100 )) && P_PCT=100
    P_SPD=${s//[[:space:]]/}; P_ETA=${e//[[:space:]]/}
    [[ $P_SPD == *nknown* || $P_SPD == NA ]] && P_SPD=""
    [[ $P_ETA == *nknown* || $P_ETA == NA ]] && P_ETA=""
  fi
}

pbar() {
  local p=$1 w=$2 f
  f=$(( p * w / 100 )); (( f > w )) && f=$w
  printf '%s%s%s%s%s' "$C_ACC" "$(rep '━' "$f")" "$C_LINE" "$(rep '━' $(( w - f )))" "$R"
}

job_line() {
  job_peek "$1"
  local t=${P_TITLE:-$2} w=$(( COLS - 60 )) right try
  (( w < 12 )) && w=12
  t=$(trunc "$t" "$w")
  if [[ -z $P_HAVE ]]; then right="analyse…"
  elif (( P_PCT >= 100 )); then right="finalisation…"
  else printf -v right '%3d%%  %s  %s' "$P_PCT" "$P_SPD" "$P_ETA"; fi
  try=$(<"$1/try" 2>/dev/null)
  [[ $try =~ ^[23]$ ]] && right+="  (essai $try/3)"
  printf '  %s%s%s %s%s%s%*s  %s  %s%s%s' "$C_ACC" "$3" "$R" "$C_TXT" "$t" "$R" $(( w - ${#t} )) '' \
    "$(pbar "$P_PCT" 22)" "$C_DIM" "$right" "$R"
}

err_hint() {
  case $1 in
    *403*|*Forbidden*)     printf 'YouTube refuse le flux → Outils : mettre à jour yt-dlp / installer Deno' ;;
    *"Sign in to confirm"*)       printf 'YouTube demande une connexion → Réglages : cookies du navigateur' ;;
    *"Requested format is not available"*) printf 'Format introuvable → mettre à jour yt-dlp ou installer Deno' ;;
    *ffmpeg*|*ffprobe*)    printf 'ffmpeg manquant → Outils : installer ffmpeg' ;;
    *"Unsupported URL"*)          printf 'Site non pris en charge par yt-dlp' ;;
  esac
}

# File d'attente : N téléchargements en parallèle, affichage en direct
run_queue() {
  local -a q=("$@") pid=() dir=() st=()
  local n=${#q[@]} next=0 running=0 nok=0 nerr=0 i drawn=0 spin=0 out dyn k k2 nl title r msg h
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local base="$WORK/q.$RANDOM$RANDOM"
  for (( i = 0; i < n; i++ )); do dir[i]="$base/$i"; mkdir -p "${dir[i]}"; st[i]=0; done
  CANCEL=0; trap 'CANCEL=1' INT
  cur_off; stty -echo 2>/dev/null
  while :; do
    while (( running < PARALLEL && next < n )); do
      run_job "${dir[next]}" "${q[next]}" </dev/null &
      pid[next]=$!; st[next]=1; (( running++ )); (( next++ ))
    done

    out=""
    for (( i = 0; i < n; i++ )); do
      (( st[i] == 1 )) || continue
      [[ -f ${dir[i]}/st ]] || continue
      wait "${pid[i]}" 2>/dev/null
      st[i]=2; (( running-- ))
      job_peek "${dir[i]}"; title=${P_TITLE:-${q[i]}}
      IFS=$'\t' read -r r msg <"${dir[i]}/st"
      if [[ $r == ok ]]; then
        (( nok++ ))
        out+="  ${C_OK}✓${R} ${C_TXT}$(trunc "$title" $(( COLS - 6 )))${R}"$'\n'
      else
 (( nerr++ ))
 out+="  ${C_ERR}✗${R} ${C_TXT}$(trunc "$title" $(( COLS - 6 )))${R}"$'\n'
        out+="    ${C_DIM}$(trunc "${msg#ERROR: }" $(( COLS - 6 )))${R}"$'\n'
        h=$(err_hint "$msg"); [[ -n $h ]] && out+="    ${C_WARN}$(trunc "$h" $(( COLS - 6 )))${R}"$'\n'
      fi
    done

    spin=$(( (spin + 1) % 10 )); dyn=""
    for (( i = 0; i < n; i++ )); do
      (( st[i] == 1 )) && dyn+="$(job_line "${dir[i]}" "${q[i]}" "${frames:spin:1}")"$'\n'
    done
    if (( nok + nerr < n )); then
      dyn+="  ${C_DIM}$(( nok + nerr ))/$n · $running en cours · Échap = annuler${R}"
    fi

    (( drawn > 0 )) && printf '\r\e[%dA' "$drawn"
    printf '\r\e[J%s%s' "$out" "$dyn"
    nl=${dyn//[!$'\n']/}; drawn=${#nl}

    (( nok + nerr == n )) && break
    if (( CANCEL )); then
      for (( i = 0; i < n; i++ )); do (( st[i] == 1 )) && kill_tree "${pid[i]}"; done
      wait 2>/dev/null
      printf '\r\e[J  %s■ Annulé%s · %d terminé(s), %d interrompu(s)\n' "$C_WARN" "$R" "$(( nok + nerr ))" "$(( n - nok - nerr ))"
      break
    fi
    if IFS= read -rsn1 -t 0.3 k; then
      if [[ $k == $'\e' ]]; then k2=""; IFS= read -rsn2 -t 0.02 k2; [[ -z $k2 ]] && CANCEL=1
      elif [[ $k == q || $k == Q ]]; then CANCEL=1; fi
    fi
  done
  trap 'exit 130' INT
  stty echo 2>/dev/null; cur_on
  printf '\n\n'
  if (( n == 1 && nok == 1 )); then
    local f; f=$(grep -a '^@@F ' "${dir[0]}/log" | tail -n1); f=${f#@@F }
    say_ok "${B}Terminé.${R}"
    [[ -n $f ]] && say_dim "→ $(short_path "$f")"
  elif (( n > 1 )); then
    printf '  %s%d réussi(s)%s · %s%d échec(s)%s\n' "$C_OK" "$nok" "$R" "$C_ERR" "$nerr" "$R"
  fi
}

# ── Écran « Télécharger » ────────────────────────────────────────────
collect_urls() {
  URLS=()
  local line w f u c; local -A seen=()
  hdr; section "↓" "Téléchargement"
  say_dim "Colle un ou plusieurs liens (un par ligne ou séparés par des espaces)."
  say_dim "Tu peux aussi glisser un fichier .txt contenant des liens. Ligne vide = valider."
  printf '\n'; cur_on
  while IFS= read -r -e -p "  › " line; do
    line=${line//$'\r'/}
    [[ -z ${line//[[:space:]]/} ]] && break
    f=${line#"${line%%[![:space:]]*}"}; f=${f%"${f##*[![:space:]]}"}
    f=${f#\'}; f=${f%\'}; f=${f#file://}
    if [[ -f $f ]]; then
      c=0
      while IFS= read -r u || [[ -n $u ]]; do
        u=${u//[[:space:]]/}
        if [[ $u =~ ^https?:// && -z ${seen[$u]} ]]; then seen[$u]=1; URLS+=("$u"); (( c++ )); fi
      done <"$f"
      say_ok "$c lien(s) importé(s) depuis ${f##*/}"
      continue
    fi
    set -f
    for w in $line; do
      if [[ $w =~ ^https?:// ]]; then
        [[ -z ${seen[$w]} ]] && { seen[$w]=1; URLS+=("$w"); }
      else say_warn "Ignoré (pas un lien) : $w"; fi
    done
    set +f
    printf '  %s%d lien(s) en attente%s\n' "$C_DIM" "${#URLS[@]}" "$R"
  done
}

show_card() {
  local url=$1 out n t up du site th tu k j s col=3
  local -a pl=(--no-playlist) info=() thl=()
  (( PLAYLIST )) && pl=(--yes-playlist)
  printf '  %s⠿%s %sAnalyse du lien…%s' "$C_ACC" "$R" "$C_DIM" "$R"
  out=$(timeout 60 yt-dlp --no-colors --no-warnings --flat-playlist -I 1:100 "${pl[@]}" "${COOKIE_ARGS[@]}" \
        --print $'%(title)s\x1f%(uploader,channel,playlist_uploader|—)s\x1f%(duration_string|—)s\x1f%(extractor_key)s\x1f%(thumbnail|)s' \
 -- "$url" 2>"$WORK/analyse.err")
  printf '\r\e[2K'
  if [[ -z $out ]]; then
    s=$(grep -a -m1 '^ERROR' "$WORK/analyse.err"); s=${s#ERROR: }
    say_warn "Analyse impossible : $(trunc "${s:-pas de réponse}" $(( COLS - 25 )))"
    say_dim "Tentative de téléchargement quand même…"; printf '\n'
    return
  fi
  n=$(grep -c '' <<<"$out")
  IFS=$'\x1f' read -r t up du site th <<<"${out%%$'\n'*}"

  if (( n == 1 )) && [[ -n $th ]] && have chafa && have curl && (( COLS >= 90 )); then
    tu=$th
    [[ $tu == *ytimg.com/vi_webp/* ]] && { tu=${tu/vi_webp/vi}; tu=${tu%.webp}.jpg; }
    if curl -fsL --max-time 8 -o "$WORK/thumb" "$tu" 2>/dev/null; then
      mapfile -t thl < <(chafa -f symbols --animate=off -s 34x12 "$WORK/thumb" 2>/dev/null | sed 's/\x1b\[?25[lh]//g')
      (( ${#thl[@]} )) && col=40
    fi
  fi

  local w=$(( COLS - col - 2 ))
  if (( n > 1 )); then
    s="Playlist · $n éléments"; (( n >= 100 )) && s+="+"
    info+=("${B}${C_TXT}${s}${R}" "${C_DIM}1er : $(trunc "$t" $(( w - 6 )))${R}" "")
  else
    info+=("${B}${C_TXT}$(trunc "$t" "$w")${R}" "")
  fi
  info+=("${C_DIM}Chaîne    ${C_TXT}$(trunc "$up" $(( w - 10 )))${R}")
  (( n == 1 )) && info+=("${C_DIM}Durée     ${C_TXT}${du}${R}")
  info+=("${C_DIM}Site      ${C_TXT}${site}${R}"
  "${C_DIM}Format    ${C_TXT}${FMT_LABEL}${R}"
         "${C_DIM}Dossier   ${C_TXT}$(trunc "$(short_path "$DL_DIR")" $(( w - 10 )))${R}")
  have ffmpeg || info+=("" "${C_WARN}ffmpeg manquant : fusion/conversion impossible${R}")

  local rows=${#thl[@]} off=0
  (( ${#info[@]} > rows )) && rows=${#info[@]}
  (( ${#thl[@]} > ${#info[@]} )) && off=$(( (${#thl[@]} - ${#info[@]}) / 2 ))
  for (( k = 0; k < rows; k++ )); do
    j=$(( k - off )); s=""
    (( j >= 0 && j < ${#info[@]} )) && s=${info[j]}
    printf '  %s%s\e[%dG%s%s\n' "${thl[k]}" "$R" "$col" "$s" "$R"
  done
  printf '\n'
}

ensure_ytdlp() {
  have yt-dlp && return 0
  say_err "yt-dlp est introuvable."; printf '\n'
  menu 0 "L'installer maintenant" "Retour"
  (( REPLY_IDX == 0 )) || return 1
  printf '\n'; install_ytdlp; pause
  have yt-dlp
}

do_download() {
  if ! have yt-dlp; then hdr; section "↓" "Téléchargement"; ensure_ytdlp || return; fi
  collect_urls
  (( ${#URLS[@]} )) || return
  choose_format || return
  if ! mkdir -p -- "$DL_DIR" 2>/dev/null; then say_err "Impossible de créer $DL_DIR"; pause; return; fi
  build_args
  hdr; section "↓" "Téléchargement"
  if (( ${#URLS[@]} == 1 )); then show_card "${URLS[0]}"
  else
    say_dim "${#URLS[@]} liens · $FMT_LABEL · $PARALLEL en parallèle"
    have ffmpeg || say_warn "ffmpeg manquant : fusion/conversion impossible"
    printf '\n'
  fi
  run_queue "${URLS[@]}"
  pause
}

# ── Mode web (100 % bash + socat) ────────────────────────────────────
lan_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  [[ -z $ip ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '%s' "${ip:-127.0.0.1}"
}

web_tui_lines() {
  local -a ds=("$WORK"/web/*/)
  local i c=0 d r msg
  if [[ ! -d ${ds[0]} ]]; then printf '%s' "  ${C_DIM}En attente d'un lien depuis le téléphone…${R}"; return; fi
  for (( i = ${#ds[@]} - 1; i >= 0 && c < 6; i-- )); do
    d=${ds[i]%/}; [[ -f $d/url ]] || continue
    (( c++ )); (( c > 1 )) && printf '\n'
    if [[ -f $d/st ]]; then
      job_peek "$d"; IFS=$'\t' read -r r msg <"$d/st"
      if [[ $r == ok ]]; then printf '  %s✓%s %s' "$C_OK" "$R" "$(trunc "${P_TITLE:-$(<"$d/url")}" $(( COLS - 8 )))"
      else printf '  %s✗%s %s' "$C_ERR" "$R" "$(trunc "${P_TITLE:-$(<"$d/url")} — ${msg#ERROR: }" $(( COLS - 8 )))"; fi
    else
      job_line "$d" "$(<"$d/url")" "↓"
    fi
  done
}

web_mode() {
  hdr; section "◎" "Mode web · depuis le téléphone"
  if ! have socat && ! have ncat; then
    say_warn "Le mode web a besoin de socat (petit outil réseau, pas de Python)."
    printf '\n'; menu 0 "Installer socat maintenant" "Retour"
    (( REPLY_IDX == 0 )) || return
    printf '\n'; pkg_install socat
    have socat || { say_err "socat n'a pas pu être installé."; pause; return; }
    hdr; section "◎" "Mode web · depuis le téléphone"
  fi
  have yt-dlp || say_warn "yt-dlp est introuvable : les téléchargements échoueront (voir Outils)."

  mkdir -p "$WORK/web" "$DL_DIR"
  ln -sfn "$SELF" "$WORK/ms"
  export MS_WORK="$WORK" MS_SELF="$SELF"
  : >"$WORK/srv.err"
  if have socat; then
    socat "TCP-LISTEN:$PORT,reuseaddr,fork" "EXEC:bash $WORK/ms --http" 2>>"$WORK/srv.err" &
  else
    ncat -lk -p "$PORT" --sh-exec "bash $WORK/ms --http" 2>>"$WORK/srv.err" &
  fi
  SRV_PID=$!
  sleep 0.6
  if ! kill -0 "$SRV_PID" 2>/dev/null; then
    SRV_PID=""
    say_err "Le serveur web n'a pas pu démarrer (port $PORT déjà utilisé ?)."
    sed 's/^/    /' "$WORK/srv.err" | head -n 5
    pause; return
  fi

  local url="http://$(lan_ip):$PORT"
  say_dim "Ouvre cette adresse sur ton téléphone (même Wi-Fi) :"
  printf '\n    %s%s%s%s\n\n' "$B" "$C_ACC" "$url" "$R"
  if have qrencode; then qrencode -t ANSIUTF8 -m 1 "$url" | sed 's/^/    /'; printf '\n'
  else say_dim "(installe qrencode dans Outils pour afficher un QR code)"; fi
  if have ufw; then say_dim "Pare-feu : si le téléphone ne se connecte pas → sudo ufw allow $PORT/tcp"
  elif have firewall-cmd; then say_dim "Pare-feu : si besoin → sudo firewall-cmd --add-port=$PORT/tcp"; fi
  printf '\n  %sÉchap ou q pour arrêter le serveur%s\n\n' "$C_LINE" "$R"

  local drawn=0 k k2 dyn nl
  cur_off
  while :; do
    term_cols
    dyn=$(web_tui_lines)
    (( drawn > 0 )) && printf '\r\e[%dA' "$drawn"
    printf '\r\e[J%s' "$dyn"
    nl=${dyn//[!$'\n']/}; drawn=${#nl}
    if IFS= read -rsn1 -t 1 k; then
      [[ $k == q || $k == Q ]] && break
      if [[ $k == $'\e' ]]; then k2=""; IFS= read -rsn2 -t 0.02 k2; [[ -z $k2 ]] && break; fi
    fi
  done
  kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""
  cur_on; printf '\n\n'
  say_ok "Serveur arrêté. Les téléchargements lancés continuent en arrière-plan."
  pause
}

# — côté serveur : une invocation de ce script par requête HTTP —
jesc() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//[[:cntrl:]]/ }; printf '%s' "$s"; }
urldec() { local s=${1//+/ }; printf '%b' "${s//%/\\x}"; }
urlenc() {
  local s=$1 o="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    case $c in [A-Za-z0-9._~-]) o+=$c ;; *) printf -v c '%%%02X' "'$c"; o+=$c ;; esac
  done
  printf '%s' "$o"
}

http_send() {
  printf 'HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s' \
    "$1" "$2" "${#3}" "$3"
}

web_jobs_json() {
  local -a ds=("$WORK"/web/*/)
  local i c=0 d out="[" title fmt state msg file r
  for (( i = ${#ds[@]} - 1; i >= 0 && c < 20; i-- )); do
    d=${ds[i]%/}; [[ -f $d/url ]] || continue
    job_peek "$d"
    title=${P_TITLE:-$(<"$d/url")}; fmt=$(<"$d/label")
    state=wait; msg=""; file=0
    if [[ -f $d/st ]]; then
      IFS=$'\t' read -r r msg <"$d/st"; state=$r; msg=${msg#ERROR: }
      [[ $r == ok ]] && file=1
    elif [[ -n $P_HAVE ]]; then state=run; fi
    (( c++ )) && out+=","
    out+="{\"id\":\"${d##*/}\",\"title\":\"$(jesc "$title")\",\"fmt\":\"$(jesc "$fmt")\",\"state\":\"$state\",\"pct\":$P_PCT,\"speed\":\"$(jesc "$P_SPD")\",\"file\":$file,\"msg\":\"$(jesc "$msg")\"}"
  done
  printf '%s]' "$out"
}

web_new() {
  local body=$1 kv k v url="" mode=video q=1080 id d
  local IFS='&'
  for kv in $body; do
    k=${kv%%=*}; v=$(urldec "${kv#*=}")
    case $k in url) url=$v ;; mode) mode=$v ;; q) q=$v ;; esac
  done
  IFS=$' \t\n'
  url=${url//[[:space:]]/}
  if [[ ! $url =~ ^https?://. ]]; then
    http_send "400 Bad Request" "application/json" '{"error":"Lien invalide"}'; return
  fi
  case $mode in
    audio) [[ $q =~ ^(mp3|m4a|opus|flac|wav)$ ]] || q=mp3 ;;
    *) mode=video; [[ $q =~ ^(best|2160|1440|1080|720|480|360)$ ]] || q=1080 ;;
  esac
  id=$(date +%s%N); d="$WORK/web/$id"; mkdir -p "$d"
  printf '%s' "$url" >"$d/url"; printf '%s' "$mode" >"$d/mode"; printf '%s' "$q" >"$d/q"
  FMT_MODE=$mode; [[ $mode == audio ]] && FMT_A=$q || FMT_Q=$q
  fmt_label; printf '%s' "$FMT_LABEL" >"$d/label"
  if have setsid; then setsid bash "$MS_SELF" --webjob "$d" </dev/null >/dev/null 2>&1 &
  else nohup bash "$MS_SELF" --webjob "$d" </dev/null >/dev/null 2>&1 & fi
  http_send "200 OK" "application/json" "{\"id\":\"$id\"}"
}

web_file() {
  local id=${1#id=} f name size
  id=${id%%&*}
  if [[ ! $id =~ ^[0-9]+$ || ! -d $WORK/web/$id ]]; then http_send "404 Not Found" "text/plain" "introuvable"; return; fi
  f=$(grep -a '^@@F ' "$WORK/web/$id/log" 2>/dev/null | tail -n1); f=${f#@@F }
  if [[ ! -f $f ]]; then http_send "404 Not Found" "text/plain" "fichier introuvable"; return; fi
  name=${f##*/}; size=$(stat -c %s -- "$f")
  printf 'HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: %s\r\nContent-Disposition: attachment; filename="%s"; filename*=%s%s\r\nConnection: close\r\n\r\n' \
    "$size" "${name//[^A-Za-z0-9._ -]/_}" "UTF-8''" "$(urlenc "$name")"
  cat -- "$f"
}

http_handle() {
  LC_ALL=C
  local line method path len=0 body="" route qs=""
  IFS= read -r -t 10 line || return
  line=${line%$'\r'}
  read -r method path _ <<<"$line"
  while IFS= read -r -t 10 line; do
    line=${line%$'\r'}; [[ -z $line ]] && break
    case ${line,,} in content-length:*) len=${line#*:}; len=${len//[!0-9]/} ;; esac
  done
  [[ -z $len ]] && len=0
  (( len > 0 && len < 65536 )) && IFS= read -r -N "$len" -t 10 body
  route=${path%%\?*}; [[ $path == *\?* ]] && qs=${path#*\?}
  case "$method $route" in
    "GET /"|"GET /index.html") http_send "200 OK" "text/html; charset=utf-8" "$(web_html)" ;;
    "GET /api/jobs")    http_send "200 OK" "application/json" "$(web_jobs_json)" ;;
    "POST /api/dl")     web_new "$body" ;;
    "GET /api/file")    web_file "$qs" ;;
    "GET /favicon.ico")        http_send "204 No Content" "text/plain" "" ;;
    *)           http_send "404 Not Found" "text/plain" "404" ;;
  esac
}

web_job() {
  local d=$1 q
  FMT_MODE=$(<"$d/mode"); q=$(<"$d/q")
  if [[ $FMT_MODE == audio ]]; then FMT_A=$q; else FMT_Q=$q; fi
  mkdir -p "$DL_DIR"
  build_args
  run_job "$d" "$(<"$d/url")"
}

web_html() {
cat <<'HTML'
<!doctype html>
<html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#17110d"><title>Maelström</title>
<style>
:root{--bg:#17110d;--card:#221a14;--line:#3b2f25;--txt:#efe4d6;--dim:#a6957f;--acc:#f0965a;--acc2:#e8705f;--ok:#96c882;--err:#eb6e64}
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
body{font:15px/1.4 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:var(--txt);background:var(--bg);background-image:radial-gradient(120% 55% at 50% -5%,#3a2416 0%,transparent 70%);min-height:100vh;padding:calc(26px + env(safe-area-inset-top)) 16px 40px}
.w{max-width:520px;margin:0 auto}
.logo{font-weight:700;font-size:14px;letter-spacing:.5em;background:linear-gradient(90deg,var(--acc),var(--acc2));-webkit-background-clip:text;background-clip:text;color:transparent}
.sub{color:var(--dim);font-size:13px;margin:6px 0 22px}
.card{background:var(--card);border:1px solid var(--line);border-radius:20px;padding:16px;box-shadow:0 10px 30px #0006}
input{width:100%;padding:14px 15px;border-radius:13px;border:1px solid var(--line);background:#130e0b;color:var(--txt);font-size:16px;outline:none;transition:border-color .2s}
input:focus{border-color:var(--acc)}
.seg{display:flex;gap:8px;margin:12px 0}
.seg button{flex:1;padding:12px;border-radius:13px;border:1px solid var(--line);background:none;color:var(--dim);font-size:15px;font-weight:600;transition:.2s}
.seg button.on{color:var(--txt);border-color:var(--acc);background:#2e2219}
select{width:100%;padding:13px;border-radius:13px;border:1px solid var(--line);background:#130e0b;color:var(--txt);font-size:15px;appearance:none;-webkit-appearance:none}
.go{width:100%;margin-top:12px;padding:15px;border:0;border-radius:14px;background:linear-gradient(90deg,var(--acc),var(--acc2));color:#1b120b;font-size:16px;font-weight:700;transition:transform .1s,opacity .2s}
.go:active{transform:scale(.98)}.go:disabled{opacity:.5}
.msg{min-height:18px;font-size:13px;color:var(--err);margin-top:8px;text-align:center}
h2{font-size:11px;letter-spacing:.25em;color:var(--dim);margin:26px 6px 10px}
.job{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:13px 14px;margin-bottom:10px;animation:in .3s ease}
@keyframes in{from{opacity:0;transform:translateY(6px)}}
.t{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.m{display:flex;justify-content:space-between;gap:10px;font-size:12px;color:var(--dim);margin-top:4px}
.bar{height:5px;border-radius:9px;background:#130e0b;margin-top:10px;overflow:hidden}
.bar i{display:block;height:100%;width:0;border-radius:9px;background:linear-gradient(90deg,var(--acc),var(--acc2));transition:width .6s}
.ok .bar i{background:var(--ok)}.err .bar i{background:var(--err)}
.e{font-size:12px;color:var(--err);margin-top:8px;word-break:break-word}
.get{display:inline-block;margin-top:11px;padding:8px 12px;border-radius:10px;border:1px solid var(--line);color:var(--acc);font-size:13px;font-weight:600;text-decoration:none}
.empty{color:var(--dim);font-size:13px;text-align:center;padding:16px}
</style></head><body><div class="w">
<div class="logo">✦ MAELSTRÖM</div>
<div class="sub">Téléchargeur universel · envoie un lien, le PC s'occupe du reste</div>
<div class="card">
<input id="u" type="url" inputmode="url" placeholder="Colle un lien (YouTube, TikTok, Insta…)" autocomplete="off">
<div class="seg"><button id="bv" class="on" type="button">▶ Vidéo</button><button id="ba" type="button">♪ Audio</button></div>
<select id="q"></select>
<button class="go" id="go" type="button">Télécharger sur le PC</button>
<div class="msg" id="msg"></div>
</div>
<h2>TÉLÉCHARGEMENTS</h2>
<div id="list"><div class="empty">Rien pour l'instant.</div></div>
</div>
<script>
const $=s=>document.querySelector(s);let mode='video';
const Q={video:[['best','Meilleure qualité'],['2160','2160p · 4K'],['1440','1440p · 2K'],['1080','1080p · Full HD'],['720','720p · HD'],['480','480p'],['360','360p']],
audio:[['mp3','MP3'],['m4a','M4A'],['opus','OPUS'],['flac','FLAC · sans perte'],['wav','WAV']]};
function fill(){$('#q').innerHTML=Q[mode].map(([v,l])=>`<option value="${v}">${l}</option>`).join('');
$('#q').value=mode=='video'?'1080':'mp3';$('#bv').classList.toggle('on',mode=='video');$('#ba').classList.toggle('on',mode=='audio')}
$('#bv').onclick=()=>{mode='video';fill()};$('#ba').onclick=()=>{mode='audio';fill()};fill();
async function send(){const u=$('#u').value.trim();$('#msg').textContent='';
if(!/^https?:\/\//i.test(u)){$('#msg').textContent='Colle un lien valide (https://…)';$('#u').focus();return}
$('#go').disabled=true;
try{const r=await fetch('/api/dl',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({url:u,mode,q:$('#q').value})});
if(!r.ok){const j=await r.json().catch(()=>({}));$('#msg').textContent=j.error||'Erreur serveur'}else{$('#u').value='';poll()}}
catch(e){$('#msg').textContent='PC injoignable : Maelström est-il toujours en mode web ?'}
$('#go').disabled=false}
$('#go').onclick=send;$('#u').addEventListener('keydown',e=>{if(e.key==='Enter')send()});
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function render(j){if(!j.length){$('#list').innerHTML='<div class="empty">Rien pour l\'instant.</div>';return}
$('#list').innerHTML=j.map(x=>{const s=x.state,cls=s=='ok'?'ok':s=='err'?'err':'',pct=s=='ok'?100:(s=='err'?100:x.pct);
const right=s=='ok'?'Terminé ✓':s=='err'?'Échec':s=='wait'?'Analyse…':(x.pct>=100?'Finalisation…':x.pct+'%'+(x.speed?' · '+esc(x.speed):''));
return `<div class="job ${cls}"><div class="t">${esc(x.title)}</div><div class="m"><span>${esc(x.fmt)}</span><span>${right}</span></div><div class="bar"><i style="width:${pct}%"></i></div>`+
(s=='ok'&&x.file?`<a class="get" href="/api/file?id=${x.id}">⤓ Récupérer sur le téléphone</a>`:'')+(s=='err'?`<div class="e">${esc(x.msg)}</div>`:'')+`</div>`}).join('')}
async function poll(){try{const r=await fetch('/api/jobs',{cache:'no-store'});render(await r.json())}catch(e){}}
setInterval(poll,1500);poll();
</script></body></html>
HTML
}

# ── Écrans secondaires ───────────────────────────────────────────────
folder_menu() {
  local d
  while :; do
    hdr; section "▤" "Dossier de téléchargement"
    say_dim "Actuel : $(short_path "$DL_DIR")"; printf '\n'
    menu 0 "Ouvrir dans le gestionnaire de fichiers" "Changer de dossier" "Remettre le dossier par défaut" "Retour"
    case $REPLY_IDX in
      0) mkdir -p -- "$DL_DIR"; open_path "$DL_DIR" ;;
      1) printf '\n'; ask "Nouveau dossier (Tab pour compléter) :" "$DL_DIR"
         d=${ANSWER/#\~/$HOME}
  if [[ -n $d ]] && mkdir -p -- "$d" 2>/dev/null; then DL_DIR=$(cd -- "$d" && pwd); save_config
         else say_err "Dossier invalide."; pause; fi ;;
      2) DL_DIR=$(default_dir); save_config ;;
      *) return ;;
    esac
  done
}

show_history() {
  hdr; section "≡" "Historique"
  local d s f t p
  if [[ -s $HIST ]]; then
    while IFS=$'\x1f' read -r d s f t p; do
      if [[ $s == ok ]]; then printf '  %s✓%s ' "$C_OK" "$R"; else printf '  %s✗%s ' "$C_ERR" "$R"; fi
      printf '%s%s%s  %s%s%s  %s%s%s\n' "$C_DIM" "$d" "$R" "$C_TXT" "$(trunc "$t" $(( COLS - 50 )))" "$R" "$C_LINE" "$f" "$R"
    done < <(tail -n 14 "$HIST" | tac)
  else
    say_dim "Aucun téléchargement pour l'instant."
  fi
  printf '\n'
  menu 0 "Ouvrir le dossier de téléchargement" "Effacer l'historique" "Retour"
  case $REPLY_IDX in 0) open_path "$DL_DIR" ;; 1) : >"$HIST" ;; esac
}

settings() {
  local sel=0 i
  local -a ck=("" firefox chrome chromium brave edge vivaldi opera)
  while :; do
    hdr; section "✦" "Réglages"
    fmt_label
    menu "$sel" \
      "Format par défaut     $FMT_LABEL" \
      "Téléchargements simultanés   $PARALLEL" \
      "Liens de playlist     $( (( PLAYLIST )) && echo 'playlist entière' || echo 'vidéo seule')" \
      "Sous-titres fr/en intégrés   $(yn "$SUBS")" \
      "Retirer les sponsors         $(yn "$SPONSOR")" \
      "Miniature + métadonnées      $(yn "$EMBED")" \
      "Cookies du navigateur ${COOKIES:-aucun}" \
      "Port du mode web      $PORT" \
      "Retour"
    (( REPLY_IDX < 0 || REPLY_IDX == 8 )) && return
    sel=$REPLY_IDX
    case $sel in
      0) choose_format ;;
      1) PARALLEL=$(( PARALLEL % 5 + 1 )) ;;
      2) PLAYLIST=$(( 1 - PLAYLIST )) ;;
      3) SUBS=$(( 1 - SUBS )) ;;
      4) SPONSOR=$(( 1 - SPONSOR )) ;;
      5) EMBED=$(( 1 - EMBED )) ;;
      6) for i in "${!ck[@]}"; do [[ ${ck[i]} == "$COOKIES" ]] && break; done
  COOKIES=${ck[(i + 1) % ${#ck[@]}]} ;;
      7) printf '\n'; ask "Nouveau port (1024-65535) :" "$PORT"
  [[ $ANSWER =~ ^[0-9]+$ ]] && (( ANSWER >= 1024 && ANSWER <= 65535 )) && PORT=$ANSWER ;;
    esac
    save_config
  done
}

tools_menu() {
  local sel=0 t v
  while :; do
    hdr; section "⟳" "Outils & mises à jour"
    for t in yt-dlp ffmpeg deno socat chafa qrencode; do
      if have "$t"; then v=$(tool_ver "$t"); printf '  %s●%s %-9s %s%s%s\n' "$C_OK" "$R" "$t" "$C_DIM" "${v:-installé}" "$R"
      else printf '  %s●%s %-9s %smanquant%s\n' "$C_ERR" "$R" "$t" "$C_DIM" "$R"; fi
    done
    printf '\n'
    menu "$sel" "Tout installer / réparer" "Mettre à jour yt-dlp" "yt-dlp nightly (si YouTube bloque encore)" \
      "Installer / mettre à jour Deno" "Installer ffmpeg" "Installer socat (mode web)" \
      "Installer chafa + qrencode (miniatures, QR code)" "Vider le cache de yt-dlp" "Retour"
    (( REPLY_IDX < 0 || REPLY_IDX == 8 )) && return
    sel=$REPLY_IDX; printf '\n'
    case $sel in
      0) if have yt-dlp; then update_ytdlp; else install_ytdlp; fi
  have ffmpeg || install_ffmpeg
         have deno   || install_deno
  have socat  || have ncat || pkg_install socat
  { have chafa && have qrencode; } || pkg_install chafa qrencode ;;
      1) if have yt-dlp; then update_ytdlp; else install_ytdlp; fi ;;
      2) [[ -x $TOOLS/yt-dlp ]] || install_ytdlp
  step "Passage en version nightly…"; "$TOOLS/yt-dlp" --update-to nightly 2>&1 | sed 's/^/    /' ;;
      3) install_deno ;;
      4) install_ffmpeg ;;
      5) pkg_install socat ;;
      6) pkg_install chafa qrencode ;;
      7) yt-dlp --rm-cache-dir 2>&1 | sed 's/^/    /' ;;
    esac
    hash -r; pause
  done
}

# ── Démarrage ────────────────────────────────────────────────────────
cleanup() {
  local p
  [[ -n $SRV_PID ]] && kill "$SRV_PID" 2>/dev/null
  for p in $(jobs -p); do kill_tree "$p"; done
  if [[ -n $WORK ]]; then for p in $(pgrep -f -- "--webjob $WORK/" 2>/dev/null); do kill_tree "$p"; done; fi
  stty echo 2>/dev/null; cur_on; printf '%s' "$R"
  [[ -n $WORK && $WORK == /tmp/maelstrom.* && -d $WORK ]] && rm -rf -- "$WORK"
}

usage() {
  cat <<EOF
Maelström v$VERSION — Linux
  ./maelstrom.sh       interface interactive
  ./maelstrom.sh URL [URL…]   téléchargement direct avec le format par défaut
EOF
}

main() {
  [[ -t 0 && -t 1 ]] || { echo "Maelström doit être lancé dans un terminal."; exit 1; }
  WORK=$(mktemp -d /tmp/maelstrom.XXXXXX) || exit 1
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir -p -- "$DL_DIR" 2>/dev/null

  if [[ ${1:-} =~ ^https?:// ]]; then
    hdr; section "↓" "Téléchargement"
    ensure_ytdlp || exit 1
    build_args
    (( $# == 1 )) && show_card "$1"
    run_queue "$@"
    return
  fi

  first_check
  local sel=0
  while :; do
    hdr; printf '\n'
    menu "$sel" \
      "↓  Télécharger · un ou plusieurs liens" \
      "◎  Mode web · depuis le téléphone" \
      "▤  Dossier de téléchargement" \
      "≡  Historique" \
      "✦  Réglages" \
      "⟳  Outils & mises à jour" \
      "×  Quitter"
    (( REPLY_IDX >= 0 )) && sel=$REPLY_IDX
    case $REPLY_IDX in
      0) do_download ;; 1) web_mode ;; 2) folder_menu ;; 3) show_history ;;
      4) settings ;; 5) tools_menu ;; 6) break ;;
    esac
  done
  printf '\e[H\e[2J\n  %s✦ À bientôt.%s\n\n' "$C_ACC" "$R"
}

load_config
case "${1:-}" in
  --http)    [[ -n $WORK ]] || exit 1; http_handle; exit 0 ;;
  --webjob)  [[ -n $WORK && -d ${2:-} ]] || exit 1; web_job "$2"; exit 0 ;;
  -h|--help) usage; exit 0 ;;
esac
main "$@"
