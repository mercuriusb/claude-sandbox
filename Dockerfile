# Claude Code Sandbox
FROM eclipse-temurin:25-jdk

# === Basis-Tools ===
# curl, git, find, grep, sed, jq: Standard-Unix-Tools die Claude Code intensiv nutzt
# ripgrep (rg): WICHTIGSTER Tool - Claude Code bevorzugt rg gegenüber grep für alle Suchen
# fd-find: modernes 'find' - schneller und einfacher
# yq: jq für YAML (wichtig für Maven pom.xml, Docker Compose, GitHub Actions)
# diffutils, patch: für Diffs und Patches
# postgresql-client: psql - ohne das sind die ParadeDB-/Suche-Skills nur Theorie
# sqlite3: das CLI; libsqlite3-0 allein nützt Claude nichts
# git-lfs: ohne das klont ein LFS-Repo still kaputt (Pointer statt Inhalt)
# shellcheck: dieses Repo ist zu weiten Teilen Bash
# tmux: für Prozesse die einen einzelnen Tool-Call überleben sollen
# rsync: Voraussetzung unzähliger Build- und Deploy-Skripte
# graphviz, pandoc: Diagramme und Dokumentkonvertierung
RUN apt-get update && apt-get install -y \
    bash \
    build-essential \
    ca-certificates \
    clang \
    cmake \
    curl \
    diffutils \
    fd-find \
    ffmpeg \
    g++ \
    gawk \
    gcc \
    git \
    git-lfs \
    golang-go \
    gosu \
    graphviz \
    htop \
    httpie \
    imagemagick \
    jq \
    less \
    libcurl4-openssl-dev \
    libedit2 \
    libncurses-dev \
    libpython3-dev \
    libsqlite3-0 \
    libvips-dev \
    libvips42t64 \
    libz3-dev \
    make \
    netcat-openbsd \
    nmap \
    openssl \
    pandoc \
    patch \
    postgresql-client \
    procps \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    rsync \
    ruby \
    sed \
    shellcheck \
    sqlite3 \
    tcpdump \
    tmux \
    tree \
    unzip \
    wget \
    xz-utils \
    zip \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# fd-find legt Binary als 'fdfind' an - Alias auf 'fd' setzen
RUN ln -s $(which fdfind) /usr/local/bin/fd

# git-lfs systemweit in die git-Config eintragen, sonst ist das Paket wirkungslos
RUN git lfs install --system

# Maven (neuere Version als apt anbietet)
ARG MAVEN_VERSION=3.9.6
RUN curl -fsSL https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz \
    | tar -xz -C /opt && \
    ln -s /opt/apache-maven-${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn

# Gradle - 'current' fragt die offizielle Versions-API, sonst konkrete Version angeben
ARG GRADLE_VERSION=current
RUN set -eux; \
    version="${GRADLE_VERSION}"; \
    if [ "$version" = "current" ]; then \
        version="$(curl -fsSL https://services.gradle.org/versions/current | jq -r .version)"; \
    fi; \
    curl -fsSL "https://services.gradle.org/distributions/gradle-${version}-bin.zip" -o /tmp/gradle.zip; \
    unzip -q /tmp/gradle.zip -d /opt; \
    rm /tmp/gradle.zip; \
    ln -s "/opt/gradle-${version}/bin/gradle" /usr/local/bin/gradle; \
    gradle --version

# Node.js + npm (für Claude Code Installer). 20 ist EOL - 24 ist das aktuelle LTS.
# corepack liefert pnpm/yarn ohne separate Installation (wichtig für die Frontend-Skills).
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y nodejs && \
    corepack enable && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# yq - jq für YAML (pom.xml, docker-compose, etc.). Architektur passend wählen, sonst läuft
# das amd64-Binary im arm64-Image nur dort, wo der Host x86 emuliert (z. B. OrbStack).
RUN set -eux; \
    case "$(uname -m)" in \
        x86_64|amd64)   yq_arch=amd64 ;; \
        aarch64|arm64)  yq_arch=arm64 ;; \
        *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}" \
        -o /usr/local/bin/yq; \
    chmod +x /usr/local/bin/yq; \
    yq --version

# === Playwright + Chromium ===
# Die Frontend-Skills (frontend-design, tailwind, daisyui, htmx) produzieren UI, die Claude
# ohne Browser nicht ansehen kann. Browser landen unter /opt statt im Home, damit kein Mount
# und kein UID-Wechsel sie erwischt; a+rwX, damit ein Projekt mit abweichender Playwright-
# Version seinen eigenen Browser danebenlegen kann.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers
ARG PLAYWRIGHT_VERSION=latest
RUN npx --yes playwright@${PLAYWRIGHT_VERSION} install --with-deps chromium && \
    chmod -R a+rwX ${PLAYWRIGHT_BROWSERS_PATH} && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Claude-User anlegen (UID wird später per Entrypoint überschrieben)
RUN useradd -m -s /bin/bash claude

# === Swift-Toolchain (Linux) ===
# linux-swift-setup.sh lädt die offizielle Swift-Linux-Toolchain und legt zwei Shim-Libs ab
# (libxml2.so.2, libicuuc.so.66), die der Ubuntu-24.04-Build erwartet, die dieses Basis-Image
# (Ubuntu 26.04) aber nur unter neueren SONAMEs mitliefert.
# Ausgangs-Script installiert nach $HOME und schreibt eine zu sourcende env-Datei. Für die
# Sandbox installieren wir stattdessen systemweit nach /opt/swift und legen Toolchain-PATH +
# Shim-Libs global fest, damit `swift` für jeden User direkt einsatzbereit ist.
#
# WITH_SWIFT=0 lässt alles Swift-/Apple-Spezifische weg: Toolchain (~3,3 GB), xcodeproj-Gem,
# XcodeGen, SwiftLint und swift-parse-check. Gedacht für lokale Builds ohne Apple-Projekte.
# PATH/LD_LIBRARY_PATH zeigen dann auf ein nicht vorhandenes /opt/swift - das ist harmlos.
ARG WITH_SWIFT=1
ENV SWIFT_PREFIX=/opt/swift \
    SWIFT_LINKLIBS=/opt/swift/linklibs
COPY linux-swift-setup.sh /tmp/linux-swift-setup.sh
RUN if [ "${WITH_SWIFT}" = "1" ]; then \
        SWIFT_ENV=/tmp/swiftenv.sh /tmp/linux-swift-setup.sh && rm /tmp/swiftenv.sh; \
    else echo "Swift-Toolchain uebersprungen"; fi && \
    rm /tmp/linux-swift-setup.sh
ENV PATH="/opt/swift/usr/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/swift/linklibs"

# === Swift-Werkzeuge für Apple-Projekte (brauchen kein Apple-SDK) ===
# macOS-/iOS-Apps lassen sich hier grundsätzlich nicht bauen: AppKit, UIKit und SwiftUI stecken
# in den Apple-SDKs, die nur mit Xcode kommen und lizenzrechtlich an Apple-Hardware gebunden
# sind. `swiftc -typecheck` scheitert an jedem `import UIKit`, xcodebuild und Simulator gibt es
# nur auf macOS. Die Werkzeuge hier kommen ohne SDK aus und decken den Rest ab: UI-freie
# Kern-Targets bauen und testen, linten, Projektdateien pflegen, Syntax prüfen.

# xcodeproj (Ruby): .pbxproj lesen und schreiben - Targets, Build-Settings, Dateireferenzen.
# Damit lassen sich Xcode-Projekte pflegen, ohne sie zu bauen.
RUN if [ "${WITH_SWIFT}" != "1" ]; then echo "xcodeproj uebersprungen"; exit 0; fi; \
    gem install --no-document xcodeproj && ruby -e 'require "xcodeproj"'

# XcodeGen: .xcodeproj aus einer project.yml erzeugen, statt pbxproj-Merge-Konflikte von Hand
# aufzulösen. Aus dem Quellcode gebaut - die Release-Assets sind reine macOS-Binaries.
ARG XCODEGEN_VERSION=2.46.0
RUN set -eux; \
    if [ "${WITH_SWIFT}" != "1" ]; then echo "XcodeGen uebersprungen"; exit 0; fi; \
    git clone --depth 1 --branch "${XCODEGEN_VERSION}" \
        https://github.com/yonaskolb/XcodeGen /tmp/xcodegen; \
    swift build -c release --package-path /tmp/xcodegen --scratch-path /tmp/xcodegen-build; \
    install -m 0755 /tmp/xcodegen-build/release/xcodegen /usr/local/bin/xcodegen; \
    rm -rf /tmp/xcodegen /tmp/xcodegen-build; \
    xcodegen --version

# SwiftLint: prüft auch UIKit-/SwiftUI-Code, weil die Rules über SwiftSyntax laufen und kein
# SDK brauchen - 250 der 255 Rules (Stand 0.65.0) stehen zur Verfügung. Es fehlen nur die 5
# Analyzer-Rules (`swiftlint analyze`), die ein Compiler-Log aus einem echten xcodebuild-Lauf
# brauchen.
# Der Build dauert nativ rund 5 Minuten; im emulierten amd64-Teil eines Multi-Arch-Builds
# entsprechend länger. Zum Überspringen: --build-arg WITH_SWIFTLINT=0 (oder WITH_SWIFT=0).
ARG SWIFTLINT_VERSION=0.65.0
ARG WITH_SWIFTLINT=1
RUN set -eux; \
    if [ "${WITH_SWIFT}" != "1" ] || [ "${WITH_SWIFTLINT}" != "1" ]; then \
        echo "SwiftLint uebersprungen"; exit 0; fi; \
    git clone --depth 1 --branch "${SWIFTLINT_VERSION}" \
        https://github.com/realm/SwiftLint /tmp/swiftlint; \
    swift build -c release --package-path /tmp/swiftlint --scratch-path /tmp/swiftlint-build; \
    install -m 0755 /tmp/swiftlint-build/release/swiftlint /usr/local/bin/swiftlint; \
    rm -rf /tmp/swiftlint /tmp/swiftlint-build; \
    swiftlint version

# === Ab hier alles als claude-User ===
# Wichtig: alles was der Container zur Laufzeit braucht, muss dem claude-User gehören und
# unter /home/claude liegen. Ein Install als root nach /root ist zur Laufzeit unerreichbar
# (/root ist 0700), und /home/claude/.claude wird beim Start vom Host überlagert.
USER claude
ENV HOME=/home/claude

# Claude Code installieren. CLAUDE_VERSION wird von der CI auf die Version gesetzt, unter der
# das Image getaggt wird - sonst behauptet das Tag eine Version, die im Image gar nicht steckt.
ARG CLAUDE_VERSION=latest
ENV PATH="/home/claude/.local/bin:${PATH}"
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_VERSION}" && \
    installed="$(claude --version | awk '{print $1}')" && \
    echo "Installed Claude Code ${installed}" && \
    if [ "${CLAUDE_VERSION}" != "latest" ] && [ "${CLAUDE_VERSION}" != "stable" ] \
       && [ "${installed}" != "${CLAUDE_VERSION}" ]; then \
        echo "FEHLER: erwartet ${CLAUDE_VERSION}, installiert ${installed}" >&2; exit 1; \
    fi

# Quarkus CLI via JBang
ENV PATH="/home/claude/.jbang/bin:${PATH}"
RUN curl -Ls https://sh.jbang.dev | bash && \
    jbang trust add https://repo1.maven.org/maven2/io/quarkus && \
    jbang app install --fresh quarkus@quarkusio

# uv - Python 3.14 steht unter PEP 668, 'pip3 install' scheitert an
# externally-managed-environment. uv liefert venvs/Tools ohne das System-Python anzufassen.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && uv --version

# tea - CLI für Forgejo/Gitea (Issues, PRs, CI-Runs). Kein apt-Paket und die Release-Assets
# tragen die Version im Namen, deshalb aus dem Quellcode gebaut - Go ist ohnehin im Image.
ENV PATH="/home/claude/go/bin:${PATH}"
RUN go install code.gitea.io/tea@latest && \
    tea --version && \
    go clean -cache -modcache

# Entrypoint als root
USER root

# swift-parse-check: `swiftc -parse` über die geänderten Dateien. Fängt Syntaxfehler in
# UI-Code ab, der sich mangels SDK nicht typechecken lässt. Bewusst weit unten im Dockerfile,
# damit eine Änderung am Skript nicht die teuren Toolchain-Layer invalidiert.
COPY swift-parse-check /usr/local/bin/swift-parse-check

# Managed Settings: gelten unabhängig vom gemounteten ~/.claude und lassen sich dort nicht
# überstimmen. Das Artifact-Tool (HTML-Seiten auf claude.ai veröffentlichen) kostet ~12.500
# Tokens bei JEDER Anfrage, nur für seine Beschreibung, und wurde in der Sandbox nie benutzt.
# Ein deny-Eintrag nimmt es ganz aus dem Prompt (gemessen: 35.978 -> 23.445 Tokens Grundlast).
RUN mkdir -p /etc/claude-code && \
    printf '%s\n' '{"permissions":{"deny":["Artifact"]}}' > /etc/claude-code/managed-settings.json

# Auto-Compact spätestens bei ~200k Kontext statt beim Modell-Default (gemessen: ~360k). Jede
# Anfrage schickt den ganzen Verlauf mit; in einer Sitzung mit mehreren Themen lagen 34 % aller
# Kontext-Tokens oberhalb von 150k. Nur ein Sicherheitsnetz - bei Themenwechsel hilft /clear
# mehr. Als ENV statt Managed Setting, damit `-e CLAUDE_CODE_AUTO_COMPACT_WINDOW=` (leer) es pro
# Start wieder aufheben kann. `auto` nimmt die Variable nicht an, nur Größen von 100k bis 1M.
ENV CLAUDE_CODE_AUTO_COMPACT_WINDOW=200k

COPY entrypoint.sh /entrypoint.sh
# Ohne Toolchain ist swift-parse-check nutzlos - dann gar nicht erst anbieten.
RUN chmod +x /entrypoint.sh && \
    if [ "${WITH_SWIFT}" = "1" ]; then chmod +x /usr/local/bin/swift-parse-check; \
    else rm /usr/local/bin/swift-parse-check; fi

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
