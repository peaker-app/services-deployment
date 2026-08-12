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
credenciales de RabbitMQ, `AuthToken__PrivateKeyPem` y las de Cloudinary. El correo de confirmación
no necesita ninguna credencial en local: sale por SMTP contra el contenedor `mailpit`. Después:

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
| ingress (nginx) → portal web | 3000 |
| gateway | 8080 |
| auth · account · peak · ascent | 8081 · 8082 · 8083 · 8084 |
| `db-auth-service` · `db-account-service` (MySQL) | 3307 · 3308 |
| `db-peak-service` · `db-ascent-service` (PostgreSQL) | 5433 · 5434 |
| RabbitMQ (AMQP · management) | 5672 · 15672 |
| Mailpit (SMTP · bandeja de entrada) | 1025 · 8025 |

**Todos esos puertos se publican en `127.0.0.1`, no en `0.0.0.0`.** El único que escucha en todas
las interfaces es el del `ingress`. La regla innegociable 6 —«todo pasa por el gateway»— no la
garantiza la aplicación: quien alcance la red interna se salta el rate limiting, las cabeceras de
seguridad y el correlation ID, y `peak-service` no tiene ni autenticación ni límite propio
(`ARCHITECTURE.md` §11, hallazgo S-10). Fuera de desarrollo local no se publica ninguno.

El portal se sirve **detrás de un ingress nginx**, no directamente: `web` deja de publicar el 3000 y
lo publica `ingress`, que fija `X-Forwarded-For` con la IP real del visitante. Sin esa cabecera el
gateway ve siempre la IP del contenedor `web` y su rate limiting se convierte en un único cubo
compartido por todo el portal (`DESIGN.md` §3.2). La URL de acceso no cambia:
<http://localhost:3000>.

Los correos de confirmación de cuenta no salen a internet en local: `auth-service` los envía a
`mailpit`, y se leen en <http://localhost:8025>. En producción la misma implementación apunta al
relay autenticado de OVH cambiando `EmailConfirmation__Smtp__*` (`DESIGN.md` §4.6).

## Rotar la clave de firma de los JWT

`auth-service` es el emisor único y custodio de la clave privada RS256; el resto de servicios
validan contra el JWKS que publica en `/.well-known/jwks.json`. El `kid` **no se configura**: se
deriva del SHA-256 de la clave pública, así que cambia solo cuando cambia la clave.

Rotar sin cortar el servicio exige publicar las dos claves a la vez durante una ventana de
solapamiento. `AuthToken__PreviousPrivateKeyPem` existe para eso: si está presente y su `kid` no
coincide con el de la actual, el JWKS publica **dos** entradas y `auth-service` acepta tokens
firmados con cualquiera de ellas.

1. Generar la clave nueva:

   ```bash
   openssl genrsa -out auth-signing-new.pem 2048
   ```

2. En `config/auth-service.env`, mover la clave que está en uso a `AuthToken__PreviousPrivateKeyPem`
   y poner la nueva en `AuthToken__PrivateKeyPem` (ambas en una línea, con `
` como salto).

3. Reiniciar solo `auth-service`. Desde ese momento firma con la nueva y sigue aceptando la antigua.

4. **Esperar** más que la suma de dos plazos antes de retirar la anterior:

   - `Jwt__MetadataAutomaticRefreshInterval` (5 min por defecto), que es lo que tardan los demás
     servicios en releer el JWKS;
   - `AuthToken__AccessTokenLifetime` (15 min), que es lo que viven los tokens ya emitidos.

   Veinte minutos cubren las dos con margen.

5. Vaciar `AuthToken__PreviousPrivateKeyPem` y reiniciar `auth-service` otra vez.

Comprobaciones: `curl -s http://127.0.0.1:8081/.well-known/jwks.json` debe devolver dos claves con
`kid` distinto durante el paso 3 y una sola tras el paso 5. Y `/health/ready` de `gateway`,
`account-service` y `ascent-service` incluye un check `jwks`: si el JWKS no se resuelve, el servicio
**no llega a estar listo** en lugar de devolver 401 en silencio.

Si `auth-service` no responde al caducar la caché, los validadores siguen aceptando tokens con la
última configuración buena conocida (`ValidateWithLKG`, hasta
`Jwt__MetadataLastKnownGoodLifetime`, 24 h por defecto): una caída de auth degrada el alta de sesión,
no tumba toda la autorización.

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
