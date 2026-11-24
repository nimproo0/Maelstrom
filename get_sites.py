# get_sites.py — MAELSTRÖM
# Télécharge la liste officielle des sites yt-dlp et l'injecte
# directement dans index.html (bloc window.__MAELSTROM_DATA__).
# Aucune expression régulière : rien qui puisse être abîmé au copier-coller.
# Usage : placer ce fichier à côté de index.html puis lancer  python3 get_sites.py

import json
import shutil
import sys
import urllib.request

URL = "https://raw.githubusercontent.com/yt-dlp/yt-dlp/master/supportedsites.md"
HTML = "index.html"
BS = chr(92)  # antislash, écrit ainsi pour éviter tout souci de copier-coller


def parse_sites(md):
    data = []
    for raw in md.splitlines():
        line = raw.strip()
        if not line.startswith("- **"):
     continue
        end = line.find("**", 4)
 if end == -1:
            continue
        name = line[4:end].strip()
        rest = line[end + 2:].strip()
 desc = rest[1:].strip() if rest.startswith(":") else rest

        broken = "Currently broken" in desc
 desc = desc.replace("(**Currently broken**)", "")
 desc = desc.replace("**Currently broken**", "")

 # retire les mentions du type [*youtube*](## "netrc machine")
        while "[*" in desc:
     a = desc.find("[*")
     b = desc.find(")", a)
     if b == -1:
         break
     desc = desc[:a] + desc[b + 1:]

        desc = " ".join(desc.split())
        if not name:
     continue
        data.append({
     "name": name,
     "desc": desc,
            "description": desc,
     "working": not broken,
     "broken": broken,
     "status": "broken" if broken else "ok",
 })
    return data


def find_value_end(s, start):
    """Renvoie l'index juste après la valeur JS qui commence à `start`."""
    if s[start] in "[{":
        depth = 0
        quote = None
        escaped = False
        for j in range(start, len(s)):
     c = s[j]
     if quote:
         if escaped:
      escaped = False
  elif c == BS:
      escaped = True
         elif c == quote:
      quote = None
  continue
     if c in "\"'`":
         quote = c
     elif c in "[{":
  depth += 1
     elif c in "]}":
         depth -= 1
         if depth == 0:
      return j + 1
        return -1
    # valeur simple (null, undefined, ...) : jusqu'au prochain ;
    j = s.find(";", start)
    return j if j != -1 else -1


def main():
    print("Téléchargement de la liste officielle yt-dlp...")
    md = urllib.request.urlopen(URL, timeout=30).read().decode("utf-8")
    data = parse_sites(md)
    if len(data) < 500:
        sys.exit("Erreur : seulement %d sites trouvés, liste anormale. Rien n'a été modifié." % len(data))

    try:
 with open(HTML, encoding="utf-8") as f:
            html = f.read()
    except FileNotFoundError:
        sys.exit("Erreur : index.html introuvable. Lance le script dans le même dossier que index.html.")

    marker = None
    for m in ("window.__MAELSTROM_DATA__ =", "window.__MAELSTROM_DATA__="):
 if m in html:
            marker = m
     break
    if marker is None:
        sys.exit("Erreur : ligne 'window.__MAELSTROM_DATA__ =' introuvable dans index.html.")
    if html.count(marker) > 1:
        print("Attention : plusieurs blocs trouvés, seul le premier est remplacé.")

    pos = html.find(marker) + len(marker)
    while pos < len(html) and html[pos] in " \t\r\n":
        pos += 1
    end = find_value_end(html, pos)
    if end == -1:
        sys.exit("Erreur : impossible de trouver la fin du bloc de données. Rien n'a été modifié.")
    if end < len(html) and html[end] == ";":
        end += 1

    payload = json.dumps(data, ensure_ascii=False)
    payload = payload.replace("</", "<" + BS + "/")  # ne casse jamais la balise </script>
    new_block = "window.__MAELSTROM_DATA__ = " + payload + ";"

    start = html.find(marker)
    shutil.copyfile(HTML, HTML + ".bak")
    html = html[:start] + new_block + html[end:]
    with open(HTML, "w", encoding="utf-8") as f:
        f.write(html)

    broken = sum(1 for d in data if d["broken"])
    print("OK : %d extracteurs injectés (%d hors service)." % (len(data), broken))
    print("Sauvegarde de l'ancien fichier : index.html.bak")
    if "cdn-cgi" in html:
        print("Attention : il reste du 'cdn-cgi' (Cloudflare) dans index.html, à supprimer avant le déploiement.")


if __name__ == "__main__":
    main()
