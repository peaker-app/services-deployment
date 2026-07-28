#!/usr/bin/env bash
# Exporta ConnectionStrings__<Servicio>Database leyendo las credenciales de
# config/<servicio>-service.env. Gemelo de Use-DevDatabase.ps1; ver su cabecera para el porque.
#
# Uso:  source ./scripts/use-dev-database.sh auth

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "Usa 'source ./scripts/use-dev-database.sh <servicio>' o la variable no persistira." >&2
    exit 1
fi

peaker_use_dev_database() {
    local service="$1"
    local key engine port
    local script_dir env_file database user password

    case "$service" in
        auth)    key='AuthDatabase';    engine='mysql';    port=3307 ;;
        account) key='AccountDatabase'; engine='mysql';    port=3308 ;;
        peak)    key='PeakDatabase';    engine='postgres'; port=5433 ;;
        ascent)  key='AscentDatabase';  engine='postgres'; port=5434 ;;
        *)
            echo "Servicio desconocido: '$service'. Usa auth, account, peak o ascent." >&2
            return 1
            ;;
    esac

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    env_file="$script_dir/../config/$service-service.env"

    if [ ! -f "$env_file" ]; then
        echo "No existe $env_file. Copia el .env.example correspondiente y completalo." >&2
        return 1
    fi

    peaker_read_env_value() {
        sed -n "s/^[[:space:]]*$1=//p" "$env_file" | head -n 1 | tr -d '\r'
    }

    if [ "$engine" = 'mysql' ]; then
        database="$(peaker_read_env_value MYSQL_DATABASE)"
        user="$(peaker_read_env_value MYSQL_USER)"
        password="$(peaker_read_env_value MYSQL_PASSWORD)"
    else
        database="$(peaker_read_env_value POSTGRES_DB)"
        user="$(peaker_read_env_value POSTGRES_USER)"
        password="$(peaker_read_env_value POSTGRES_PASSWORD)"
    fi

    unset -f peaker_read_env_value

    if [ -z "$database" ] || [ -z "$user" ] || [ -z "$password" ]; then
        echo "Faltan credenciales en $env_file (usuario, contrasena o nombre de base de datos)." >&2
        return 1
    fi

    if [ "$engine" = 'mysql' ]; then
        export "ConnectionStrings__$key=server=localhost;port=$port;database=$database;user=$user;password=$password"
    else
        export "ConnectionStrings__$key=Server=localhost;Port=$port;Database=$database;Username=$user;Password=$password"
    fi

    echo "ConnectionStrings__$key -> localhost:$port/$database (usuario: $user)"
}

peaker_use_dev_database "$1"
