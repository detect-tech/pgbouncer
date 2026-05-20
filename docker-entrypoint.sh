#!/bin/sh
#
# pgbouncer container entrypoint.
#
# When the command being run is pgbouncer, ensures the config files exist:
#   - If /etc/pgbouncer/pgbouncer.ini is mounted in (or baked by a child
#     image), it is used as-is and no env vars are read.
#   - Otherwise, the ini and userlist.txt are generated from env vars.
#
# Any other command (e.g. `sh`) bypasses the setup so the container can be
# inspected for debugging.
#
# Env vars used during generation:
#
#   DB_HOST                     upstream postgres host (required)
#   DB_PORT                     upstream port              (default: 5432)
#   DB_NAME                     "*" to forward any db name (default: *)
#   DB_USER                     used to populate userlist.txt
#   DB_PASSWORD                 password for DB_USER
#   DB_PASSWORD_FILE            path to a file holding DB_PASSWORD (K8s/Docker secrets)
#
#   LISTEN_ADDR                 (default: 0.0.0.0)
#   LISTEN_PORT                 (default: 6432)
#   POOL_MODE                   session | transaction | statement   (default: transaction)
#   MAX_CLIENT_CONN             (default: 100)
#   DEFAULT_POOL_SIZE           (default: 20)
#   AUTH_TYPE                   md5 | scram-sha-256 | trust | ...   (default: md5)
#   ADMIN_USERS                 comma-separated  (default: $DB_USER)
#   STATS_USERS                 comma-separated  (default: empty)
#   SERVER_RESET_QUERY          (default: "DISCARD ALL")
#   IGNORE_STARTUP_PARAMETERS   (default: extra_float_digits)
#   SERVER_TLS_SSLMODE          disable | prefer | require | verify-ca | verify-full
#   CLIENT_TLS_SSLMODE          disable | allow  | require | verify-ca | verify-full

set -eu

CONFIG_DIR=/etc/pgbouncer
INI=${CONFIG_DIR}/pgbouncer.ini
USERLIST=${CONFIG_DIR}/userlist.txt

# If <VAR>_FILE is set, load the file contents into <VAR>. Pattern used by
# Kubernetes secrets and `docker secret` mounts.
load_file_var() {
    var=$1
    eval "file_val=\${${var}_FILE:-}"
    if [ -n "$file_val" ]; then
        if [ ! -r "$file_val" ]; then
            echo "pgbouncer: ${var}_FILE=$file_val is not readable" >&2
            exit 1
        fi
        eval "$var=\$(cat \"\$file_val\")"
    fi
}

print_env_help() {
    cat >&2 <<'HELP'
pgbouncer: no /etc/pgbouncer/pgbouncer.ini present and DB_HOST not set.

Either mount /etc/pgbouncer/pgbouncer.ini (and userlist.txt) into the container,
or set the env vars listed at the top of /usr/local/bin/docker-entrypoint.sh.
Minimum required: DB_HOST, DB_USER, DB_PASSWORD (or DB_PASSWORD_FILE).
HELP
}

generate_config() {
    load_file_var DB_PASSWORD

    if [ -z "${DB_HOST:-}" ]; then
        print_env_help
        exit 1
    fi

    DB_PORT=${DB_PORT:-5432}
    DB_NAME=${DB_NAME:-*}
    LISTEN_ADDR=${LISTEN_ADDR:-0.0.0.0}
    LISTEN_PORT=${LISTEN_PORT:-6432}
    POOL_MODE=${POOL_MODE:-transaction}
    MAX_CLIENT_CONN=${MAX_CLIENT_CONN:-100}
    DEFAULT_POOL_SIZE=${DEFAULT_POOL_SIZE:-20}
    AUTH_TYPE=${AUTH_TYPE:-md5}
    ADMIN_USERS=${ADMIN_USERS:-${DB_USER:-}}
    STATS_USERS=${STATS_USERS:-}
    SERVER_RESET_QUERY=${SERVER_RESET_QUERY:-DISCARD ALL}
    IGNORE_STARTUP_PARAMETERS=${IGNORE_STARTUP_PARAMETERS:-extra_float_digits}

    # pgbouncer uses userlist.txt for two things:
    #   1. Client auth — only for password-based AUTH_TYPE (md5, scram-sha-256).
    #   2. Upstream auth — when connecting to postgres, regardless of AUTH_TYPE,
    #      unless postgres trusts pgbouncer with no password.
    # Require DB_USER/DB_PASSWORD for password-based client auth; allow them to
    # be omitted with trust/any only if postgres also doesn't need a password.
    case "$AUTH_TYPE" in
        trust|any)
            : ;;
        *)
            if [ -z "${DB_USER:-}" ] || [ -z "${DB_PASSWORD:-}" ]; then
                echo "pgbouncer: AUTH_TYPE=$AUTH_TYPE requires DB_USER and DB_PASSWORD" >&2
                exit 1
            fi ;;
    esac

    if [ ! -f "$USERLIST" ] && [ -n "${DB_USER:-}" ] && [ -n "${DB_PASSWORD:-}" ]; then
        (umask 077 && printf '"%s" "%s"\n' "$DB_USER" "$DB_PASSWORD" > "$USERLIST")
    fi

    # auth_type=any ignores the client-supplied username, so every database
    # route needs a forced upstream user (user=...). DB_USER is mandatory there.
    forced_user=""
    if [ "$AUTH_TYPE" = "any" ]; then
        if [ -z "${DB_USER:-}" ]; then
            echo "pgbouncer: AUTH_TYPE=any requires DB_USER (the forced upstream user)" >&2
            exit 1
        fi
        forced_user=" user=${DB_USER}"
    fi

    if [ "$DB_NAME" = "*" ]; then
        db_entry="* = host=${DB_HOST} port=${DB_PORT}${forced_user}"
    else
        db_entry="${DB_NAME} = host=${DB_HOST} port=${DB_PORT} dbname=${DB_NAME}${forced_user}"
    fi

    {
        printf '[databases]\n'
        printf '%s\n\n' "$db_entry"
        printf '[pgbouncer]\n'
        printf 'listen_addr = %s\n' "$LISTEN_ADDR"
        printf 'listen_port = %s\n' "$LISTEN_PORT"
        printf 'unix_socket_dir =\n\n'
        printf 'auth_type = %s\n' "$AUTH_TYPE"
        if [ -f "$USERLIST" ]; then
            printf 'auth_file = %s\n\n' "$USERLIST"
        else
            printf '\n'
        fi
        printf 'admin_users = %s\n' "$ADMIN_USERS"
        printf 'stats_users = %s\n\n' "$STATS_USERS"
        printf 'pool_mode = %s\n' "$POOL_MODE"
        printf 'max_client_conn = %s\n' "$MAX_CLIENT_CONN"
        printf 'default_pool_size = %s\n\n' "$DEFAULT_POOL_SIZE"
        printf 'server_reset_query = %s\n' "$SERVER_RESET_QUERY"
        printf 'ignore_startup_parameters = %s\n\n' "$IGNORE_STARTUP_PARAMETERS"
        # Log to stderr, no pidfile — container-friendly.
        printf 'logfile =\n'
        printf 'pidfile =\n'
        if [ -n "${SERVER_TLS_SSLMODE:-}" ]; then
            printf 'server_tls_sslmode = %s\n' "$SERVER_TLS_SSLMODE"
        fi
        if [ -n "${CLIENT_TLS_SSLMODE:-}" ]; then
            printf 'client_tls_sslmode = %s\n' "$CLIENT_TLS_SSLMODE"
        fi
    } > "$INI"

    echo "pgbouncer: generated $INI from env (db=${DB_NAME} host=${DB_HOST}:${DB_PORT})" >&2
}

case "$(basename "${1:-}")" in
    pgbouncer)
        if [ -f "$INI" ]; then
            echo "pgbouncer: using existing $INI" >&2
        else
            generate_config
        fi
        ;;
esac

exec "$@"
