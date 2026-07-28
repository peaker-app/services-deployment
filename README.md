# services-deployment

Stack local de Peaker con Docker Compose: los cuatro microservicios, sus bases de datos,
RabbitMQ, el gateway y el portal web. Ver `.claude/docs/DESIGN.md` §10.

## Puesta en marcha

Las credenciales viven en `config/*.env`, que **no se versionan** (`.gitignore`, regla
innegociable 8). Lo versionado son las plantillas `config/*.env.example`:

```bash
cd config
for f in *.env.example; do cp -n "$f" "${f%.example}"; done
```

Completar en cada `.env` los valores vacíos: usuarios y contraseñas de las bases de datos,
credenciales de RabbitMQ, `AuthToken__PrivateKeyPem`, la API key de Resend y las de Cloudinary.
Después:

```bash
docker compose up -d
```

Perfiles opcionales, que no se levantan en el día a día:

```bash
docker compose --profile ingestion up -d peak-ingestion   # ingesta de Wikidata
docker compose --profile quality up -d sonarqube          # SonarQube en :9000
```

| Servicio | Puerto host |
|---|---|
| portal web | 3000 |
| gateway | 8080 |
| auth · account · peak · ascent | 8081 · 8082 · 8083 · 8084 |
| `db-auth-service` · `db-account-service` (MySQL) | 3307 · 3308 |
| `db-peak-service` · `db-ascent-service` (PostgreSQL) | 5433 · 5434 |
| RabbitMQ (AMQP · management) | 5672 · 15672 |

## Trabajar con `dotnet ef` desde el host

`env_file:` solo inyecta variables dentro de un contenedor, así que `dotnet ef` no las recibe.
Además los `.env` apuntan a hostnames de Compose (`db-auth-service`) que no resuelven fuera de su
red. `scripts/Use-DevDatabase.ps1` hace el puente: lee el usuario y la contraseña del `.env` y
exporta `ConnectionStrings__<Servicio>Database` apuntando a `localhost` y al puerto publicado.

```powershell
. .\scripts\Use-DevDatabase.ps1 auth          # auth | account | peak | ascent
```

```bash
source ./scripts/use-dev-database.sh auth
```

Hace falta para `database update`, `migrations remove` y `migrations list`. Para
`migrations add` y `migrations script` no: no abren conexión. Detalle en
`.claude/docs/DEVELOPMENT.md` §8.
