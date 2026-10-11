# OpenAPI Chat

Convierte cualquier spec **OpenAPI 3.x** o **Swagger 2.0** en un chatbot que consulta la API real, usando **Apple Intelligence** (framework Foundation Models) en iOS y macOS.

Añades la spec (por URL, archivo o pegándola), configuras la autenticación que declara y preguntas en lenguaje natural: «¿qué productos hay en stock?», «enséñame el historial de precios del segundo». El modelo elige los endpoints, los llama y los resultados aparecen como tablas.

## Características

- **Cualquier spec**: OpenAPI 3.0/3.1 y Swagger 2.0, en JSON o YAML. Resuelve `$ref`, `allOf`, `oneOf`/`anyOf` y parámetros a nivel de ruta.
- **Cada operación es una tool**: los parámetros y el body se convierten en un `GenerationSchema` dinámico, sin código por API.
- **Autenticación según la spec**: API key (header, query o cookie), Bearer, HTTP Basic, OAuth 2 (token manual, client credentials o password) y OpenID Connect. Las credenciales se guardan en el llavero.
- **Tablas nativas**: las respuestas se muestran como tabla o ficha directamente desde el JSON. El modelo solo escribe un resumen corto, lo que lo hace mucho más rápido.
- **Gráficas**: si los datos tienen una gráfica evidente, se pueden ver así (Swift Charts):
  - una fecha y un número (un historial de precios) se ven como línea temporal;
  - etiquetas con un número, como barras.
- **Fichas con varias listas**: un objeto con varias listas (por ejemplo, un Pokémon con stats, tipos y movimientos) se muestra como ficha con un selector de lista. El modelo recibe todas las listas.
- **Paginación**: detecta `page`, `offset` y cursores, y añade un botón «Cargar más» que pide la página siguiente sin pasar por el modelo.
- **Encadena llamadas**: los IDs y URLs de los resultados llegan intactos al modelo, que puede usarlos en la siguiente llamada (por ejemplo, listar productos y luego consultar el historial de uno).
- **Pensado para un modelo pequeño**:
  - en cada turno solo expone las operaciones relevantes;
  - describe los `{id}` sin documentar a partir del endpoint que los lista;
  - resume las respuestas grandes;
  - le da al modelo cifras ya calculadas (recuentos, mínimos y máximos).
- **Corrige IDs cruzados**: si el modelo pone el ID de un elemento donde va el de su padre (`/stores/{id}/…`), la app lo detecta por los resultados anteriores y lo corrige antes de enviar la petición.
- **Seguro por defecto**: pide confirmación antes de cualquier `POST`, `PUT`, `PATCH` o `DELETE`.

## Cómo funciona

```
Pregunta ──► OperationRouter ──► LanguageModelSession (tools = operaciones elegidas)
                                     │
                                     ├─► OpenAPITool ─► APIExecutor ─► HTTP ─► API
                                     │                     │
                                     │                     └─► ResultPresentation ─► tabla en la UI
                                     ▼
                              respuesta breve (guided generation)
```

| Módulo | Qué hace |
|---|---|
| `APISpec` | Parsea la spec: servidores, operaciones, esquemas de seguridad y `$ref`. |
| `SchemaNormalizer` / `ToolInterface` | JSON Schema → `DynamicGenerationSchema` con argumentos planos. |
| `OperationRouter` | Elige las operaciones del turno: filtro léxico y después el propio modelo. |
| `RequestBuilder` / `AuthResolver` | Construyen la petición HTTP y aplican la autenticación. |
| `ResultPresentation` / `Pagination` | Tablas, fichas y siguiente página a partir del JSON. |
| `ChatEngine` | Orquesta la conversación, el historial y las confirmaciones. |

El núcleo vive en el paquete `Packages/OpenAPIChatKit` y no depende de SwiftUI. La app (`App/`) es SwiftUI multiplataforma.

## Requisitos

- Xcode 27 y iOS 27 o macOS 27.
- Un dispositivo con **Apple Intelligence** activado y el modelo descargado. En macOS, el idioma de Siri tiene que coincidir con el del sistema.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) para generar el proyecto.

## Desarrollo

```sh
brew install xcodegen
xcodegen generate
open OpenAPIChat.xcodeproj   # elige tu equipo en Signing & Capabilities
```

Desde la terminal:

```sh
xcodebuild -scheme OpenAPIChat -destination 'platform=macOS' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<TU_TEAM_ID> build
```

El núcleo se prueba sin Xcode:

```sh
cd Packages/OpenAPIChatKit
swift test                        # tests unitarios
LIVE_API_TESTS=1 swift test       # incluye llamadas reales a la demo de Petstore
swift run openapi-chat https://petstore3.swagger.io/api/v3/openapi.json   # chat en la terminal
```

## Enlaces `openapichat://`

Sirven para Atajos, scripts o pruebas automáticas:

```sh
open "openapichat://add?url=https://petstore3.swagger.io/api/v3/openapi.json"
open "openapichat://ask?api=Petstore&q=¿Cuántas%20mascotas%20hay%20disponibles?&new=1"
```

En las compilaciones Debug, cada turno se registra en el log unificado:

```sh
/usr/bin/log stream --level debug --predicate 'subsystem == "OpenAPIChat"'
```

## Private Cloud Compute

La app puede usar también el modelo de Apple en **Private Cloud Compute**, con más contexto, pero requiere el entitlement `com.apple.developer.private-cloud-compute`, que Apple concede bajo solicitud. Sin él, el framework cierra la app al usarlo, así que viene desactivado. Cuando tengas el entitlement, descomenta en `project.yml` la línea del entitlement y la de `PRIVATE_CLOUD_COMPUTE`.

## Limitaciones

- El modelo en el dispositivo es pequeño: a veces elige mal el endpoint o se equivoca al encadenar varios pasos. Cuanto mejor descrita esté la spec (descripciones de parámetros y esquemas de respuesta), mejor funciona.
- No hay subida de archivos (`multipart` con binarios) ni OAuth con inicio de sesión en el navegador.
- De `oneOf`/`anyOf` solo se usa la primera opción no nula.

## Licencia

[MIT](LICENSE)
