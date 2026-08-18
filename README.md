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

## Desplegar en producción: TLS y entorno `Production`

Producción se levanta con **el fichero base más un overlay**, nunca con el base a secas:

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d   # producción
docker compose up -d                                                    # desarrollo, sin cambios
```

`docker-compose.prod.yml` hace cuatro cosas: pone los cinco servicios en
`ASPNETCORE_ENVIRONMENT=Production` mediante `environment:`, que tiene precedencia sobre `env_file:`
—así los `config/*.env` siguen siendo los de desarrollo y no hay dos juegos que mantener—; despublica
todos los puertos del host salvo el 80 y el 443 del `ingress`; aparca `mailpit` bajo el perfil
`dev-mail`; y añade `certbot` con su volumen de certificados.

Poner `Production` **apaga Swagger** en los cuatro servicios y en el gateway, **exige**
`AuthToken__PrivateKeyPem` en `auth-service` —sin ella cada reinicio firmaría con una clave distinta
e invalidaría los tokens vivos— y **exige** que el SMTP vaya cifrado y autenticado. Las tres son
validaciones con `ValidateOnStart`: el flag y los secretos se ponen en el mismo despliegue, no en dos.

### Antes de empezar

- Registros `A` para `<dominio>` y `api.<dominio>` apuntando a la IP del VPS, **propagados**. La
  validación de Let's Encrypt entra desde internet resolviendo por DNS público: esto no se puede
  probar en local. Comprobar con `dig +short <dominio>` y `dig +short api.<dominio>`.
- Puertos **80 y 443 abiertos** (`sudo ufw status` y, si está activado, el Network Firewall del panel
  de OVH). El 80 **no se puede cerrar después**: se necesita en cada renovación.
- `services-deployment/.env` creado a partir de `.env.example`, con `PEAKER_DOMAIN`,
  `PEAKER_API_DOMAIN`, `NEXT_PUBLIC_SITE_URL`, los `LEGAL_*` y, si ya hay proveedor de teselas, las
  dos `NEXT_PUBLIC_MAP_*`.

Hacen falta **dos nombres**, no uno: `GATEWAY_URL` no lleva prefijo `NEXT_PUBLIC_`, así que solo lo
usa el BFF del portal en servidor y el navegador nunca habla con el gateway — pero **la app móvil
sí**, por `VITE_GATEWAY_URL`.

| Nombre | Va a | Lo consume |
|---|---|---|
| `<dominio>` | `web:3000` | el portal, y su BFF por dentro |
| `api.<dominio>` | `gateway:8080` | solo la app móvil |

### Paso 1 — emitir el certificado, en dos tiempos

Hay un problema del huevo y la gallina: nginx no arranca con un bloque `ssl_certificate` que apunte a
un fichero que aún no existe. Por eso la primera emisión se hace con una configuración solo-HTTP, que
es lo que monta `docker-compose.bootstrap.yml`:

```bash
docker compose -f docker-compose.yml -f docker-compose.bootstrap.yml up -d ingress
```

Ese overlay deja el `ingress` sirviendo únicamente `/.well-known/acme-challenge/` en el puerto 80, sin
`depends_on`, de modo que no arrastra ni el portal ni el gateway.

El ensayo **no es opcional**: Let's Encrypt limita a 5 validaciones fallidas por hora, y `--dry-run`
hace el baile completo contra su entorno de pruebas sin gastar cuota real.

```bash
# Ensayo. Si esto falla, el DNS o el puerto 80 no están bien.
docker compose -f docker-compose.yml -f docker-compose.bootstrap.yml \
  run --rm certbot certonly --webroot -w /var/www/certbot \
  -d "$PEAKER_DOMAIN" -d "$PEAKER_API_DOMAIN" \
  --email <correo> --agree-tos --no-eff-email --dry-run

# De verdad: el mismo comando sin --dry-run.
```

Un solo certificado cubre los dos nombres (`-d` repetido). Al terminar existe
`/etc/letsencrypt/live/<dominio>/fullchain.pem` dentro del volumen `certbot-conf`.

**`certbot-conf` es un volumen con nombre a propósito: sobrevive a `docker compose down`.** Sin él,
cada recreación pediría certificados nuevos, y Let's Encrypt corta a los 5 duplicados por semana: te
quedarías sin HTTPS durante días.

### Paso 2 — la cascada de URLs

TLS no es solo el certificado. Hay URLs incrustadas en varios sitios y ninguna se corrige sola:

| Dónde | Variable | A qué |
|---|---|---|
| `config/auth-service.env` | `EmailConfirmation__ConfirmationLinkTemplate` | `https://<dominio>/confirm-email?token={token}` |
| " | `EmailConfirmation__SignInLink` | `https://<dominio>/login` |
| " | `EmailConfirmation__PasswordResetLinkTemplate` | `https://<dominio>/reset-password?token={token}` |
| " | `EmailConfirmation__Smtp__*` | el relay de OVH: `ssl0.ovh.net`, `587`, `StartTls`, con credenciales |
| `.env` (raíz) | `NEXT_PUBLIC_SITE_URL` | `https://<dominio>` — **build arg** |
| `peaker-mobile/app/.env` | `VITE_GATEWAY_URL` | `https://api.<dominio>` |
| " | `VITE_SITE_URL` | `https://<dominio>` |

Las `NEXT_PUBLIC_*` y los `LEGAL_*` son **argumentos de construcción**: Next las incrusta en el bundle
durante `npm run build`. Ponerlas en `config/web.env` no tiene ningún efecto. Cambiarlas obliga a
`docker compose ... build web`, no basta con reiniciar.

### Paso 3 — levantar producción

```bash
docker compose -f docker-compose.yml -f docker-compose.bootstrap.yml down
docker compose -f docker-compose.yml -f docker-compose.prod.yml build web
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

El `ingress` pasa a montar `config/nginx/prod/`, con los dos `server` de 443. Las plantillas las
rellena el propio entrypoint de la imagen de nginx pasando `envsubst` sobre
`/etc/nginx/templates/*.template`; `NGINX_ENVSUBST_FILTER=^PEAKER_` limita la sustitución a nuestras
dos variables, para que `$host`, `$remote_addr` y `$connection_upgrade` lleguen intactos a nginx.

El `command` del `ingress` recarga nginx cada 6 h. No es decorativo: nginx **no relee el certificado
renovado por su cuenta**, así que sin esa recarga seguirías sirviendo el viejo hasta que caduque.

### Paso 4 — verificación

```bash
curl -sI https://<dominio>                    # 200, con Strict-Transport-Security
curl -sI http://<dominio>                     # 308 hacia https
curl -s  https://api.<dominio>/health/ready   # Healthy, y el check `jwks` en verde
curl -sI https://<dominio>/swagger            # 404: Production apaga Swagger
```

La prueba que de verdad cierra el despliegue no es un `curl`: **login en el portal, y comprobar en las
DevTools que `peaker_at` llega con `Secure` y que la sesión sobrevive a recargar la página.** El
portal fija `secure` en función de `NODE_ENV`, que ya vale `production`, así que sobre `http://` el
navegador descarta la cookie en silencio: el login responde 200 y el usuario sigue anónimo.

### Paso 5 — subir HSTS, y solo entonces

Las plantillas salen con `Strict-Transport-Security "max-age=300"`. Es deliberado: **HSTS es la única
cabecera de esta lista que no se puede deshacer.** Si publicas `max-age=31536000` y el certificado
falla, los navegadores que ya vieron la cabecera se niegan a conectar durante un año.

Una vez verificado el paso 4 y la renovación en seco, subirla en `config/nginx/prod/peaker.conf.template`
—los dos bloques de 443— y recargar:

```
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
```

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml restart ingress
```

### Paso 6 — probar la renovación **el primer día**

Es el fallo clásico: todo funciona, y a los 60 días el certificado no se renueva porque el puerto 80
se cerró «ya que todo va por HTTPS» o porque el volumen no era persistente. En seco cuesta un minuto:

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml \
  run --rm --entrypoint certbot certbot renew --dry-run
```

**`--entrypoint certbot` no es opcional aquí.** En el overlay de producción el `entrypoint` del
servicio es el bucle de renovación cada 12 h; sin sustituirlo, los argumentos `renew --dry-run` se
pasarían al `sh -c` del bucle y no harían nada, dando un falso verde.

### Por qué `Jwt__RequireHttpsMetadata` sigue en `false`

Es la duda que reaparece cada vez que alguien revisa esta configuración. `Jwt__Authority` es
`http://auth-service:8080`, un nombre de la red interna de Compose. `Common.API/Security/JwtExtensions.cs`
construye el `ConfigurationManager` con `new HttpDocumentRetriever { RequireHttps = ... }`, que rechaza
una URL `http:` **antes de pedirla**. Subirlo a `true` dejaría al gateway, a `account-service` y a
`ascent-service` sin poder descargar el JWKS: todas las peticiones autenticadas responderían 401 y el
check `jwks` de `/health/ready` quedaría en rojo.

Ese salto no sale de la red bridge de Compose ni cruza el host. El TLS que importa se termina en el
`ingress`. La alternativa —apuntar la autoridad a `https://api.<dominio>`— obligaría a los servicios a
salir a internet y volver por nginx solo para leer sus propias claves, con una dependencia de arranque
circular. No se hace.

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

## Cambiar la audiencia de los JWT

Cada servicio que valida tokens declara **su** audiencia en `Jwt__Audiences__0`
—`peaker-gateway`, `peaker-account`, `peaker-ascent`— y `auth-service` emite el `aud` como array
con todas ellas en `AuthToken__Audiences__n`, más `AuthToken__SelfAudience` para la suya. Así, cuando
llegue un quinto servicio, los tokens ya emitidos **no valen** contra él hasta que se le añada su
audiencia explícitamente. `peak-service` no aparece: es catálogo público y no monta autenticación.

Cambiar una audiencia rompe en los dos sentidos a la vez, así que **no se cambia de golpe**. El
patrón es el mismo que el de la rotación de clave, con una ventana de solapamiento:

1. Añadir la audiencia **nueva** al emisor, sin quitar la vieja, y reiniciar solo `auth-service`:

   ```
   AuthToken__Audiences__0=peaker-gateway
   ...
   AuthToken__Audiences__4=<audiencia nueva>
   ```

2. Añadir la audiencia nueva al validador que corresponda, junto a la que ya acepta, y reiniciarlo:

   ```
   Jwt__Audiences__0=<audiencia vieja>
   Jwt__Audiences__1=<audiencia nueva>
   ```

3. **Esperar** `AuthToken__AccessTokenLifetime` (15 min) a que caduquen los tokens ya emitidos.

4. Retirar la audiencia vieja de las dos partes y reiniciar. Si se retira antes de tiempo, todo
   token vivo emitido con la anterior pasa a devolver `401`.

Una audiencia mal escrita **ya no arranca en silencio**: `Jwt__Audiences` vacío detiene el servicio
al arrancar, y `AuthToken__SelfAudience` fuera de `AuthToken__Audiences` detiene `auth-service`, que
si no rechazaría los tokens que él mismo emite. Antes el síntoma era un `401` genérico,
indistinguible de un token inválido.

## Outbox: mensajes aparcados y cómo desaparcarlos

Todo lo crítico viaja en el outbox —correos, eventos de integración y la confirmación de los activos
de Cloudinary—, así que un mensaje que no sale es una pérdida silenciosa. El procesador reintenta con
backoff exponencial acotado (`Outbox__RetryBackoffBase` → `Outbox__RetryBackoffCap`) y, al agotar
`Outbox__MaxAttempts`, **aparca** el mensaje: deja de seleccionarlo y sigue con los de detrás. Antes
lo reintentaba para siempre, y como el lote se ordena por antigüedad, un mensaje envenenado frenaba a
todos los que venían después.

El tope de 12 intentos no es arbitrario: un envío de correo aplazado por la cuota global de 150/hora
(`DESIGN.md` §4.6) es un fallo **legítimo** que se recupera solo, y con esos plazos la ventana
cubierta pasa de dos horas.

Un mensaje aparcado se ve sin entrar en la base de datos: `/health/ready` pasa a **`Degraded`**
—respondiendo 200, sin sacar el contenedor de servicio— y el log lleva el `LogWarning` con el
recuento. La misma señal se publica como métrica (`ARCHITECTURE.md` §10).

```bash
docker compose exec db-auth-service \
  mysql -u <usuario> -p peaker_auth -e \
  "SELECT id, type, attempt_count, error FROM outbox_messages WHERE processed_at_utc IS NULL AND attempt_count >= 12;"
```

Desaparcar es **manual y deliberado**: primero se corrige la causa —un consumidor, una credencial,
un contrato—, y solo después se reintenta. Un mensaje que vuelve a la cola sin arreglar nada se
limita a gastar otros doce intentos.

```sql
UPDATE outbox_messages SET attempt_count = 0, next_attempt_at_utc = NULL WHERE id = '<id>';
```

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
