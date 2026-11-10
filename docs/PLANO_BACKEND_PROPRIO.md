# Trocar o Supabase por backend próprio (FastAPI + Postgres)

**Situação (2026-11-10):** plano documentado, ainda **não aprovado para execução**.
Falta o Zander decidir onde hospedar. Começar pela fase 1 quando ele pedir.

## Contexto

O Zander perguntou se as funcionalidades atuais permitem trocar o Supabase por um
backend próprio em FastAPI + Postgres. **Resposta: sim, e a troca é bem contida**,
porque o app foi pensado para isso sem querer:

- A tela nunca lê o servidor: lê o SQLite (drift). O servidor só aparece no
  `SyncService`, e quase todo acesso passa pela interface `RemoteGateway`
  (`lib/services/remote_gateway.dart`): upsert, upsertMany, update, selectAll,
  selectIds, selectUpdatedSince, selectByIds. Basta uma nova implementação.
- O Realtime já é "só aviso" (dispara `pull`), então o servidor próprio só precisa
  mandar "a tabela X mudou", sem conteúdo.
- O Supabase aparece em só 7 arquivos: `main.dart`, `config.dart`,
  `auth_service.dart`, `sync_service.dart`, `remote_gateway.dart`,
  `members_service.dart`, `members_screen.dart`.

O que o Supabase entrega hoje e o que precisa ser escrito:

| Supabase | Substituto |
|---|---|
| Postgres + migrações 0001–0004 | Mesmo Postgres; SQL reaproveitado quase inteiro |
| Auth (Google ID token → sessão) | FastAPI valida o ID token do Google e emite JWT próprio + refresh token |
| `auth.uid()` na RLS e nos triggers | `current_setting('app.user_id')`, definido pelo FastAPI com `SET LOCAL` a cada transação |
| PostgREST (`from().select/upsert/update`) | Poucos endpoints fixos, só os que o `RemoteGateway` usa |
| RPC `share_list` | `POST /lists/{id}/share` chamando a mesma função SQL |
| Realtime (`postgres_changes`) | WebSocket + `LISTEN/NOTIFY` do Postgres |
| HTTPS, backups, painel | Docker Compose + Caddy (HTTPS automático) + `pg_dump` agendado |

Ganhos: controle total, sem dependência de fornecedor, aprendizado de backend.
Perdas: hospedar/manter servidor, backups e segurança do login passam a ser
responsabilidade do Zander; some o painel/SQL Editor (fica `psql` ou pgAdmin).

## Abordagem recomendada

### Backend (pasta nova `backend/` no mesmo repositório)

- **Stack:** FastAPI, `asyncpg` (SQL direto, sem ORM, para manter o SQL das
  migrações como fonte da verdade), `google-auth`, `PyJWT`, Docker Compose
  (Postgres 16 + API + Caddy).
- **Esquema:** `backend/migrations/` adapta 0001–0004: tabela `users` própria
  (id UUID, `google_sub` único, e-mail, nome) no lugar de `auth.users`; função
  `app_uid()` = `current_setting('app.user_id', true)::uuid` substitui `auth.uid()`.
  **Manter a RLS e os triggers** (`touch_updated_at_and_by`,
  `items_default_position`, dono entra em `list_members`, `share_list`,
  `is_list_member`/`is_list_owner`/`shares_a_list_with`). A API conecta com um papel
  sem `BYPASSRLS`; assim a segurança continua no banco, como hoje.
- **Login:** `POST /auth/google` (valida ID token com audience = web client ID já
  usado, cria/atualiza `users` e `profiles`, devolve access JWT ~1 h + refresh
  token opaco guardado com hash), `POST /auth/refresh` (com rotação),
  `POST /auth/logout`.
- **Sincronização** (espelha o `RemoteGateway`), só para `lists`, `items`,
  `products`, com lista branca de colunas por tabela:
  - `POST /sync/{table}/upsert` (1 ou N linhas, atômico; `INSERT ... ON CONFLICT (id)
    DO UPDATE` só das colunas enviadas, equivalente a `defaultToNull: false`)
  - `PATCH /sync/{table}/{id}` → `{changed: bool}`
  - `GET /sync/{table}?since=...` / `?ids_only=1` / `?ids=a,b,c` (paginado por id)
  - Erros sempre como `{code: SQLSTATE, message}` com o código do Postgres, para a
    regra de "rejeição definitiva" do app (`_isPermanent`, `23505` em products)
    continuar valendo.
- **Participantes:** `GET /lists/{id}/members` (com nome/e-mail do profile),
  `POST /lists/{id}/share`, `DELETE /lists/{id}/members/{user_id}`,
  `GET /profiles/{id}`.
- **Tempo real:** triggers em `lists`, `items`, `list_members` fazem
  `pg_notify('changes', {table, list_id})`; a API escuta e envia pelo WebSocket
  `/ws?token=...` só para usuários conectados que são membros da lista (consulta em
  memória/cache, recarregada em mudanças de `list_members`; o removido também recebe o
  aviso). Token vencido → servidor fecha o socket.

### App Flutter

- `RemoteException(code, message)` nova, substituindo `PostgrestException` em
  `sync_service.dart` (~linhas 295–376, 689), `members_service.dart`,
  `members_screen.dart:43`.
- `ApiGateway implements RemoteGateway` (pacote `http`), no lugar de `SupabaseGateway`.
  `FakeGateway`/`InMemoryServer` dos testes continuam valendo sem mudança.
- `AuthService` reescrito: mesmo fluxo `google_sign_in` 7.x, troca o ID token em
  `/auth/google`, guarda tokens em `flutter_secure_storage`, renova antes de vencer,
  expõe um stream de estado equivalente a `onAuthStateChange` (`signedIn`,
  `tokenRefreshed`, `signedOut`) para `main.dart` e `SyncService`.
- `SyncService._connectChannel` com `web_socket_channel`; **`RealtimeKeeper` fica
  igual** (lógica pura já testada). `_ensureFreshSession` passa a usar o `AuthService`.
- `MembersService.watchMembers` deixa de usar `.stream()`: busca REST e refaz ao
  receber aviso de `list_members` pelo WebSocket.
- `config.json`/`AppConfig`: `API_URL` no lugar de `SUPABASE_URL`/chave.
  Remover `supabase_flutter` do `pubspec.yaml` no fim.

### Migração dos dados

- `pg_dump` das tabelas `public` do Supabase e `auth.users` (id, e-mail, `sub` do
  Google em `auth.identities`) → importar mantendo **os mesmos UUIDs** de usuário.
  Assim `owner_id`, `created_by`, `updated_by` e o carimbo `db_owner` do banco local
  continuam válidos e o celular não precisa apagar nada: só faz login de novo.
- Antes de instalar a versão nova, garantir fila vazia nos dois celulares.

## Fases (cada uma testada antes da próxima)

1. **Backend base:** Compose, migrações adaptadas, login Google/refresh; testes
   `pytest` contra Postgres real em Docker (RLS: usuário A não vê lista de B).
2. **Sincronização:** endpoints `/sync`, `ApiGateway`, `RemoteException`; testes do
   contrato (upsert repetido não duplica, update sem permissão → `changed=false`,
   códigos SQLSTATE).
3. **Participantes e tempo real:** share/remove/sair, WebSocket + NOTIFY, aviso só
   para membros.
4. **Troca no app:** `AuthService`, `main.dart`, config; remover `supabase_flutter`.
5. **Implantação:** servidor com HTTPS (Android recusa HTTP comum), backup diário,
   cópia dos dados do Supabase, roteiro manual com dois celulares.

## Decisões em aberto (para o Zander)

- **Onde hospedar:** VPS barata (Hetzner/Contabo, ~US$ 5/mês, Compose completo),
  PaaS (Railway/Fly/Render, menos manutenção) ou computador de casa com túnel
  (Cloudflare Tunnel). Recomendação: VPS com Compose + Caddy.
- Motivo principal da troca (custo, aprendizado, independência) muda a prioridade,
  ex.: se for aprendizado, vale manter os dois backends lado a lado por um tempo.

## Verificação

- `pytest` no `backend/` (Postgres em Docker, sem serviços externos; ID token do
  Google simulado com chave de teste).
- `flutter analyze` sem problemas e `flutter test` passando.
- Roteiro `docs/ROTEIRO_TESTES_OFFLINE.md` com dois celulares contra o servidor novo,
  mais: token vencido com app aberto (canal refaz), convite e remoção em tempo real,
  importar catálogo de 300 produtos (3 requisições).
- Atualizar `CLAUDE.md` (decisões técnicas) e `docs/GUIA_SUPABASE.md` → guia do
  servidor próprio.
