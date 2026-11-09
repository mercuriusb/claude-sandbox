#!/bin/bash
# entrypoint.sh
set -euo pipefail

HOST_UID=${HOST_UID:-1000}
HOST_GID=${HOST_GID:-1000}

warn() { echo "entrypoint: $*" >&2; }

# User 'claude' auf Host-UID anpassen
groupmod -g "$HOST_GID" claude 2>/dev/null || true
usermod -u "$HOST_UID" claude 2>/dev/null || true

# Ownership der Home-Dateien korrigieren - aber NICHT in gemountete Verzeichnisse hinein.
# Die Shell-Funktion `claude-sandbox` mountet ~/.claude vom Host hierher; ein rekursives
# chown würde die Ownership echter Host-Dateien umschreiben und bei gewachsenem ~/.claude
# (history, projects/) bei jedem Start spürbar bremsen. Deshalb: alle Mountpoints unterhalb
# /home/claude ausschneiden.
prune_args=()
while read -r _dev mountpoint _rest; do
    case "$mountpoint" in
        /home/claude/*) prune_args+=( -path "$mountpoint" -prune -o ) ;;
    esac
done < /proc/self/mounts

# Bewusst nicht fatal: ein einzelner unlesbarer Pfad darf den Container-Start nicht kippen.
if ! find /home/claude -xdev "${prune_args[@]}" -print0 \
        | xargs -0 --no-run-if-empty chown -h claude:claude; then
    warn "Warnung - chown auf /home/claude unvollstaendig"
fi

# Zusätzliche CA-Zertifikate übernehmen. Nötig für eigene Dienste mit privater CA (z.B. ein
# selbst gehostetes Forgejo): ohne das kann Claude aus der Sandbox weder klonen noch pushen
# noch die API abfragen. Zertifikate per Mount nach /usr/local/share/ca-certificates legen.
# Java hat einen EIGENEN Truststore - das System-Bundle allein reicht der JVM nicht.
install_extra_cas() {
    local dir=/usr/local/share/ca-certificates
    local jdk=/opt/java/openjdk
    compgen -G "$dir/*.crt" >/dev/null || return 0

    update-ca-certificates >/dev/null 2>&1 || warn "update-ca-certificates fehlgeschlagen"

    local cert alias_name
    if [ -x "$jdk/bin/keytool" ]; then
        for cert in "$dir"/*.crt; do
            alias_name="sandbox-$(basename "$cert" .crt)"
            # Bereits importiert -> keytool meldet Fehler, das ist hier kein Problem.
            "$jdk/bin/keytool" -importcert -cacerts -storepass changeit -noprompt \
                -alias "$alias_name" -file "$cert" >/dev/null 2>&1 || true
        done
    fi

    # Node (und damit Claude Code selbst) liest das System-Bundle nicht von sich aus.
    export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
}
install_extra_cas

# USER/LOGNAME setzen. gosu wechselt nur die UID und vererbt die Umgebung unverändert - beide
# Variablen blieben sonst leer. Etliche Werkzeuge verlassen sich darauf; XcodeGen etwa bricht
# ohne $USER mit "Couldn't find current username" ab, statt auf getpwuid zurückzufallen.
export USER=claude
export LOGNAME=claude

# Als claude-User ausführen
exec gosu claude "$@"
