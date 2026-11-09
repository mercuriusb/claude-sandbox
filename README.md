## docker build

Einmalig auf dem Mac

```sh
docker buildx create --name multiarch --driver docker-container --use
```

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg CLAUDE_VERSION=latest \
  -t registry.example.com/USERNAME/claude-sandbox:latest \
  --push \
  .
```

`CLAUDE_VERSION` wird an den Installer durchgereicht (`latest`, `stable` oder eine konkrete
Version wie `2.1.220`). Die CI setzt hier die Version ein, unter der das Image getaggt wird,
und der Build bricht ab, wenn die installierte Version davon abweicht — sonst behauptet der
Tag eine Version, die im Image gar nicht steckt.

### Build-Args

| Arg | Default | Wirkung |
|---|---|---|
| `CLAUDE_VERSION` | `latest` | Version von Claude Code |
| `WITH_SWIFT` | `1` | `0` lässt alles Swift-/Apple-Spezifische weg: Toolchain (~3,3 GB), `xcodeproj`, XcodeGen, SwiftLint, `swift-parse-check` |
| `WITH_SWIFTLINT` | `1` | `0` überspringt den SwiftLint-Build |
| `SWIFTLINT_VERSION` | `0.65.0` | Tag, der aus dem Quellcode gebaut wird |
| `XCODEGEN_VERSION` | `2.46.0` | Tag, der aus dem Quellcode gebaut wird |

SwiftLint und XcodeGen werden aus dem Quellcode gebaut — es gibt für Linux keine fertigen
Binaries. Nativ dauert das zusammen rund 6 Minuten, im emulierten `linux/amd64`-Teil des
Multi-Arch-Builds deutlich länger. Wenn dir das den Build zu sehr aufhält:

```sh
docker buildx build --build-arg WITH_SWIFTLINT=0 …
```

Ohne jeden Swift-Kram (z. B. lokal auf dem Mac, wenn du keine Apple-Projekte bearbeitest):

```sh
docker build --build-arg WITH_SWIFT=0 -t claude-sandbox:local .
```

### Wann die CI baut

`.forgejo/workflows/build.yml` — Trigger stehen in der YAML, nicht in der Forgejo-GUI.

| Anlass | Gebaut? |
|---|---|
| Nächtlich um 03:00, neue Claude-Code-Version auf npm | ja, plus Commit von `.claude-version` |
| Nächtlich, keine neue Version | nein |
| Push auf `main` | ja |
| Push auf `main`, nur `*.md` geändert | nein (`paths-ignore`) |
| Push des CI-eigenen Versions-Commits (`[skip ci]`) | nein |
| `workflow_dispatch` | ja |

Getaggt wird `:latest`, `:<claude-version>` und `:sha-<kurzer-commit>`. Die ersten beiden
wandern mit; wer ein unveränderliches Image braucht, pinnt den `sha`-Tag.

Der Job legt außerdem einen `:buildcache`-Tag in der Registry an. Ohne den würden SwiftLint
und XcodeGen bei jedem Commit neu aus dem Quellcode gebaut — im emulierten `linux/amd64`-Teil
der teuerste Posten des ganzen Builds.

## Aufruf

Als Shell-Funktion in `~/.zshrc` bzw. `~/.bashrc`:

```sh
claude-sandbox() {
  docker run --rm -it --pull always \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$(pwd)":"/workspace$(pwd)" \
    -v "$HOME/.claude":/home/claude/.claude \
    -v "$HOME/.claude.json":/home/claude/.claude.json \
    -w "/workspace$(pwd)" \
    registry.example.com/USERNAME/claude-sandbox:latest
}
```

`HOST_UID`/`HOST_GID` sind wichtig: der Entrypoint mappt den `claude`-User im Container
darauf, damit im Workspace angelegte Dateien auf dem Host dir gehören. Ohne die beiden
Variablen fällt er auf 1000/1000 zurück — auf dem Mac egal, auf einem Linux-Host mit
abweichender UID gibt das Rechteprobleme.

`.claude.json` liegt neben `~/.claude` und hält Login und Projektzustand. Ohne den zweiten
Mount fängt jede Sitzung bei null an.

### Projekt unter `/workspace` + Host-Pfad

Das Projekt landet nicht direkt unter `/workspace`, sondern unter seinem vollen Host-Pfad
darunter: `~/dev/myapp` wird zu `/workspace/Users/du/dev/myapp`. Grund ist
Claude Code selbst: Memory und Sitzungsverlauf liegen in `~/.claude/projects/<cwd>/`, wobei
`<cwd>` das Arbeitsverzeichnis mit `-` statt `/` ist. Mit einem festen `/workspace` teilen
sich alle Projekte denselben Ordner `-workspace` — Notizen aus Projekt A tauchen in Projekt B
auf, kosten dort Tokens und führen Claude auf falsche Fährten.

Warum genau diese Form:

- **Voller Pfad statt nur Ordnername:** `~/dev/foo` und `~/work/foo` bleiben getrennt.
- **Unter `/workspace` statt identisch zum Host-Pfad:** auf einem Linux-Host könnte ein
  Projekt unter `/opt` oder `/usr/local` sonst Verzeichnisse aus dem Image überdecken
  (`/opt/swift`, `/opt/java/openjdk`). Unter `/workspace` liegt im Image nichts.

Der Preis: Pfade in Fehlermeldungen tragen das Präfix `/workspace`, und ein natives `claude`
auf dem Host im selben Projekt nutzt einen anderen Memory-Ordner als die Sandbox. Dass der
Pfad Benutzername und Ordnerstruktur verrät, ist kein Verlust — beides steht über Git-Remote
und das gemountete `~/.claude` ohnehin im Container.

Wer ein Projekt verschiebt oder umbenennt, verliert damit dessen Memory-Zuordnung; der alte
Ordner unter `~/.claude/projects/` lässt sich dann von Hand umbenennen.

### Was aus der Sandbox auf den Host wirkt

Claude läuft im Container mit `--dangerously-skip-permissions`, kann also im Projekt und in
`~/.claude` alles schreiben. Die Sandbox schützt den Mac nur, solange nichts davon später
**auf dem Host** ausgeführt wird.

`~/.claude` und `~/.claude.json` sind dabei unkritisch, wenn Claude Code auf dem Mac nie
direkt gestartet wird: Hooks in `settings.json`, `mcpServers` in `.claude.json`, Plugins und
Skills wirken dann nur wieder in der Sandbox.

Der offene Weg ist das **Projektverzeichnis** — das wird auf dem Mac sehr wohl ausgeführt:

| Was | Wann es auf dem Host läuft |
|---|---|
| `.git/hooks/` | beim nächsten `git commit`, `git push`, `git checkout` … |
| Build-Skripte, Build-Phasen in `project.yml`/Xcode-Projekt | beim Build in Xcode |
| `pom.xml`/`build.gradle` (Plugins), `package.json` (`postinstall`, `scripts`) | bei `mvn`, `gradle`, `npm install` |
| `.envrc`, `.vscode/tasks.json`, Run-Konfigurationen der IDE | beim Betreten des Ordners bzw. Ausführen in der IDE |

Nach einer Sandbox-Sitzung deshalb `git status` und `git diff` ansehen — besonders Dateien,
die nicht zur eigentlichen Aufgabe gehören. `.git/hooks/` taucht dort nicht auf; aktive Hooks
zeigt `ls .git/hooks | grep -v '\.sample$'`.

#### Wenn Claude Code doch auch nativ läuft

Dann wirkt eine in der Sandbox geänderte `~/.claude/settings.json` auf dem Host — ein dort
eingetragener Hook liefe ohne Container. Ein zusätzlicher Mount sperrt die Datei:

```sh
    -v "$HOME/.claude":/home/claude/.claude \
    -v "$HOME/.claude/settings.json":/home/claude/.claude/settings.json:ro \
```

- Die Datei muss auf dem Host existieren, sonst legt Docker an ihrer Stelle ein
  *Verzeichnis* an: `[ -f ~/.claude/settings.json ] || echo '{}' > ~/.claude/settings.json`.
- In der Sandbox schlägt dann alles fehl, was `settings.json` schreibt (`/skills`, Plugins
  aktivieren, Hooks/Permissions eintragen). Änderungen auf dem Host greifen erst nach
  Neustart der Sandbox, weil der Datei-Mount am Inode hängt.

Das deckt nur den direktesten Weg ab: `~/.claude.json` (`mcpServers`) muss beschreibbar
bleiben, `plugins/` und `skills/` ebenso. Sauberer ist dann ein eigenes Verzeichnis nur für
die Sandbox (`-v "$HOME/.claude-sandbox":/home/claude/.claude` plus
`-v "$HOME/.claude-sandbox.json":/home/claude/.claude.json`), in das man `.credentials.json`
und `.claude.json` einmal hineinkopiert.

### Kein docker.sock

Bewusst nicht gemountet. `/var/run/docker.sock` im Container heißt: alles darin kann
`docker run -v /Users/du:/host …` — also dein komplettes Home lesen und schreiben, und über
`~/.zshrc` oder `~/Library/LaunchAgents` von dort aus Code auf dem Host ausführen. Das hebt
den Zweck der Sandbox auf, die ja gerade deshalb existiert, weil Claude darin mit
`--dangerously-skip-permissions` läuft.

Der Preis: **Quarkus Dev Services** und **Testcontainers** funktionieren nicht, beide starten
Hilfscontainer über die Docker-API. Die Sandbox unterstützt das bewusst nicht; solche Tests
laufen außerhalb des Containers.

## Wichtiger Hinweis zum ersten Login

Das ~/.claude-Verzeichnis entsteht erst nach dem ersten Login auf dem Host. Falls noch nicht geschehen:

```sh
# Einmalig auf dem Host (mit Browser-Login):
claude
# → Browser öffnet sich, einloggen
# → Ab dann funktioniert claude-sandbox ohne Browser
```


## Was im Image steckt

| Bereich | Werkzeuge |
|---|---|
| Java | Temurin 25, Maven, Gradle, Quarkus CLI, JBang |
| Swift | Toolchain 6.3.3 unter `/opt/swift` inkl. `swift-format`, `sourcekit-lsp`, `plutil` |
| Apple-Projekte | `swiftlint`, `xcodegen`, `xcodeproj` (Ruby), `swift-parse-check` — siehe unten |
| Node | Node 24 LTS, npm, `corepack` (pnpm/yarn), Playwright + Chromium |
| Python | 3.14, `venv`, `uv` |
| Weitere | Go, Ruby, clang/gcc/cmake |
| Daten | `psql`, `sqlite3` |
| Git/Forge | `git`, `git-lfs`, `tea` (Forgejo/Gitea-CLI) |
| Suche/Text | `rg`, `fd`, `jq`, `yq`, `shellcheck`, `pandoc`, `graphviz` |
| Medien | `ffmpeg`, `imagemagick`, `libvips` |
| Sonstiges | `tmux`, `rsync`, `httpie`, `tree`, `htop` |

### Playwright

Chromium liegt unter `/opt/playwright-browsers` (`PLAYWRIGHT_BROWSERS_PATH`) — bewusst
außerhalb des Homes, damit weder der `.claude`-Mount noch der UID-Wechsel im Entrypoint
etwas daran kaputt macht. Das Verzeichnis ist für alle schreibbar, damit ein Projekt mit
abweichender Playwright-Version seinen eigenen Browser danebenlegen kann.

## Swift: macOS- und iOS-Projekte

### Was hier nicht geht

Apps für macOS oder iOS lassen sich im Container **nicht bauen**. AppKit, UIKit und SwiftUI
stecken in den Apple-SDKs; die kommen nur mit Xcode und sind lizenzrechtlich an Apple-Hardware
gebunden. `xcodebuild`, Simulator und Codesigning gibt es ausschließlich auf macOS. Daran
ändert keine Toolchain-Installation etwas:

```
swiftc -parse     Datei.swift   # OK, auch mit import UIKit
swiftc -typecheck Datei.swift   # error: no such module 'UIKit'
```

### Die Arbeitsteilung, die das brauchbar macht

Schneide das Projekt so, dass die Logik ohne UI-Framework auskommt: ein UI-freies SPM-Target
(`…Core`), das nur `Foundation` braucht — Modell, Persistenz, Parsing, Netzwerk, Algorithmen.
Das baut und testet hier vollständig, inklusive `swift test`. Nur die View-Schicht, die
App-Extensions und der finale Build bleiben auf dem Mac.

Zwei Details, die den auf Linux testbaren Anteil wachsen lassen:

- `#if canImport(UIKit)` statt `#if os(iOS)` — fragt nach dem, worauf es ankommt.
- Plattformabhängiges (Farben, Bilder, Keychain, Dateipfade) als Protokoll im Core, die
  Darwin-Implementierung im UI-Target. Der Core bleibt testbar, ohne dass etwas fehlt.

### Werkzeuge im Image

| Werkzeug | Wofür |
|---|---|
| `swift build` / `swift test` | UI-freie Kern-Targets bauen und testen |
| `swiftlint` | Linting, 250 der 255 Rules — es fehlen nur die 5 Analyzer-Rules (`swiftlint analyze` braucht ein Compiler-Log) |
| `swift-format` | Formatierung (Teil der Toolchain) |
| `swift-parse-check` | `swiftc -parse` über geänderte Dateien — Syntaxgate für UI-Code |
| `xcodegen` | `.xcodeproj` aus `project.yml` erzeugen |
| `xcodeproj` (Ruby) | `.pbxproj` programmatisch lesen und ändern, ohne zu bauen |
| `plutil` | `Info.plist`, Entitlements, `.xcstrings` prüfen und umwandeln |

`swift-parse-check` ohne Argumente prüft alle gegenüber `HEAD` geänderten `.swift`-Dateien,
mit Argumenten die angegebenen Dateien oder Verzeichnisse:

```sh
swift-parse-check                  # geänderte Dateien
swift-parse-check Sources App/     # rekursiv
```

Es prüft ausschließlich Syntax. Ein grüner Lauf heißt "wohlgeformt", nicht "übersetzt" —
Typen, Namen und Verfügbarkeit sieht erst der Mac.

### Der eigentliche Build

Bleibt auf dem Mac. Naheliegend wäre, `xcodebuild` per SSH auf den Host durchzureichen — das
ist aber genau das, wogegen die Sandbox schützt: der Container schreibt die Sourcen, die
`.pbxproj`-Run-Script-Phasen und die SPM-Plugins, die der Mac dann ausführt. Ein "auf
xcodebuild eingeschränkter" SSH-Key ändert daran nichts, weil ein Build definitionsgemäß
beliebigen Code ausführt.

Tragfähige Varianten, von sauber nach schnell:

1. **Forgejo-Runner auf einem Mac.** Die Vertrauensgrenze ist `git push` + CI — dieselbe, die
   du bei jeder CI ohnehin akzeptierst. Kein Shell-Kanal in den Host, der Runner läuft unter
   eigenem User, Ergebnisse holst du per API. Kostet Minuten statt Sekunden Rückkopplung.
2. **Dedizierter Build-User oder macOS-VM** (z. B. Tart auf Apple Silicon) mit SSH-Zugang.
   Ohne Admin-Rechte und ohne deine Signing-Zertifikate im Keychain. Der Fluchtweg aus dem
   Container endet dann in etwas, dessen Kompromittierung du verkraftest.
3. **Manuell.** Claude sagt, was zu bauen ist, du drückst am Mac den Knopf und pastest den
   Fehler zurück. Kostet pro Runde ein paar Sekunden und hält die Grenze zu 100 %.

Für den Fall, dass gar kein Mac verfügbar ist, gibt es [xtool](https://github.com/xtool-org/xtool):
baut SPM-basierte iOS-Apps auf Linux mit einem Darwin-SDK, das du selbst aus deiner Xcode-
Installation entpackst. Das SDK ist nicht weitergabefähig und darf deshalb nicht ins Image;
Apples Lizenz bindet die Nutzung an Apple-Hardware. Für ein reines SwiftUI-SPM-Projekt
tragfähig, für ein gewachsenes Xcode-Projekt nicht.

## Eigene CA-Zertifikate

Läuft dein Forgejo (oder ein anderer interner Dienst) mit privatem CA-Zertifikat, kann Claude
aus der Sandbox heraus sonst weder klonen noch pushen noch die API abfragen. Zertifikat als
`.crt` hineinmounten:

```sh
-v "$HOME/certs/my-ca.crt":/usr/local/share/ca-certificates/my-ca.crt:ro
```

Der Entrypoint ruft dann `update-ca-certificates` auf, importiert das Zertifikat zusätzlich in
den Truststore des JDK (die JVM benutzt das System-Bundle nicht) und setzt
`NODE_EXTRA_CA_CERTS` für Node und Claude Code selbst.

## Token-Verbrauch

`/etc/claude-code/managed-settings.json` im Image sperrt das `Artifact`-Tool (HTML-Seiten auf
claude.ai veröffentlichen). Allein seine Beschreibung kostet ~12.500 Tokens bei jeder Anfrage,
ob es benutzt wird oder nicht — gemessen sinkt die Grundlast damit von 35.978 auf 23.445
Tokens. Managed Settings stehen über `~/.claude/settings.json`; wer das Tool zurückhaben will,
muss die Zeile im Dockerfile entfernen und neu bauen.

`CLAUDE_CODE_AUTO_COMPACT_WINDOW=200k` lässt Claude Code spätestens bei ~200k Kontext
kompaktieren statt beim Modell-Default (beobachtet: ~360k). Jede Anfrage schickt den ganzen
Verlauf mit — wer in einer Sitzung von Nextcloud zu Keycloak wechselt, bezahlt bei jeder
Keycloak-Frage den Nextcloud-Verlauf mit. Das ist nur ein Netz: bei Themenwechsel ist `/clear`
oder `/compact <was behalten werden soll>` besser, weil dann du entscheidest, was wegfällt.
Für eine Sitzung mit großer Einzelaufgabe, die nicht mittendrin kompaktieren soll, die
Variable leer setzen — dann gilt wieder der Modell-Default (`auto` nimmt sie nicht an):

```sh
docker run … -e CLAUDE_CODE_AUTO_COMPACT_WINDOW= …
```

## Skills

Das Image bringt keine Skills mit. Die Sandbox sieht die Skills aus `~/.claude/skills` auf dem
Host, weil `~/.claude` gemountet ist — installiert und gepflegt werden sie also dort.

---

# Forgejo als Container Registry nutzen

## 1. Forgejo vorbereiten

In der `app.ini` auf dem Forgejo-Server sicherstellen dass Packages aktiviert sind:

```ini
[packages]
ENABLED = true
```

Prüfbar unter `https://forgejo.example.com/-/admin/config`.

---

## 2. Access Token erstellen

In Forgejo unter **Settings → Applications → Token generieren** — wichtig: der User muss **Admin-Rechte** haben, damit er in die Package-Registry pushen darf.

---

## 3. Docker einloggen

Credentials direkt in `~/.docker/config.json` schreiben, da `osxkeychain` auf macOS die Credentials nicht an den buildx-Container weitergibt:

```bash
# Base64 generieren
echo -n "USERNAME:TOKEN" | base64
```

In `~/.docker/config.json` eintragen:

```json
{
  "auths": {
    "forgejo.example.com": {
      "auth": "DEIN_BASE64"
    }
  },
  "credsStore": "osxkeychain",
  "currentContext": "orbstack"
}
```

---

## 4. Multi-Arch Builder einrichten

Der Standard-Docker-Driver unterstützt kein Multi-Platform — einmalig einen neuen Builder erstellen:

```bash
docker buildx create \
  --name multiarch \
  --driver docker-container \
  --use
```

---

## 5. Image bauen und pushen

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t forgejo.example.com/USERNAME/IMAGE:latest \
  --push \
  .
```

---

## 6. Image nutzen

```bash
docker pull forgejo.example.com/USERNAME/IMAGE:latest
```

Aufgerufen wird es über die Shell-Funktion `claude-sandbox` aus [Aufruf](#aufruf).

---

## Stolpersteine

| Problem | Ursache | Lösung |
|---|---|---|
| `401 reqPackageAccess` beim Push | Forgejo-User hat keine Admin-Rechte | User in Forgejo Admin-Rechte geben |
| Credentials werden nicht an buildx weitergegeben | macOS `osxkeychain` ist für buildx-Container nicht zugänglich | Base64-Credentials direkt in `config.json` schreiben |
| `Multi-platform build is not supported` | Standard Docker-Driver unterstützt kein Multi-Platform | buildx Builder mit `docker-container` Driver erstellen |
| Bestehender Builder lässt sich nicht neu erstellen | Builder existiert bereits | `docker buildx rm multiarch` dann neu erstellen |
| Token hat keine Package-Rechte | Token wurde vor Package-Aktivierung erstellt | Neues Token nach Package-Aktivierung erstellen |
---

# Lokal bauen und verwenden (ohne Registry)

Für den eigenen Rechner brauchst du weder Registry noch Multi-Arch-Builder. Ein normaler
`docker build` baut das Image für die Architektur des Hosts (auf Apple Silicon `arm64`) und
legt es direkt im lokalen Docker ab (Docker Desktop, OrbStack, Colima …).

## Bauen

Im Verzeichnis dieses Repos:

```sh
docker build -t claude-sandbox:local .
```

Mit den [Build-Args](#build-args) lässt sich der Build verschlanken, z. B. ohne alles
Swift-/Apple-Spezifische (spart den Download der ~3,3 GB großen Swift-Toolchain und die
Builds von SwiftLint und XcodeGen aus dem Quellcode):

```sh
docker build --build-arg WITH_SWIFT=0 -t claude-sandbox:local .
```

Eine bestimmte Claude-Code-Version statt `latest`:

```sh
docker build --build-arg CLAUDE_VERSION=2.1.316 -t claude-sandbox:local .
```

Neu bauen, z. B. für eine neue Claude-Code-Version: einfach denselben Befehl wiederholen.
Docker nimmt unveränderte Schichten aus dem Cache. Soll Claude Code trotz unverändertem
Dockerfile neu installiert werden, hilft `--no-cache` (baut dann aber alles neu) oder eine
konkrete `CLAUDE_VERSION`.

## Verwenden

Die Funktion aus [Aufruf](#aufruf) startet mit `--pull always` und würde ein lokal gebautes
Image überschreiben bzw. mit einem Pull-Fehler abbrechen, weil es `claude-sandbox:local` in
keiner Registry gibt. Für das lokale Image deshalb eine eigene Funktion in `~/.zshrc` bzw.
`~/.bashrc`, ohne `--pull`:

```sh
claude-sandbox-local() {
  docker run --rm -it \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$(pwd)":"/workspace$(pwd)" \
    -v "$HOME/.claude":/home/claude/.claude \
    -v "$HOME/.claude.json":/home/claude/.claude.json \
    -w "/workspace$(pwd)" \
    claude-sandbox:local
}
```

Aufruf im Projektverzeichnis:

```sh
cd ~/dev/myapp
claude-sandbox-local
```

Alles andere — Mounts, eigene CA-Zertifikate, erster Login — gilt wie oben beschrieben.

Alte, nicht mehr referenzierte Image-Schichten sammeln sich bei häufigem Neubauen an:

```sh
docker image prune     # entfernt verwaiste (<none>) Images
```
