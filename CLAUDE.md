# Lista de Compras: contexto para o Claude Code

App Flutter para compartilhar listas de compras de supermercado entre várias
pessoas (ex.: um casal montando a lista da semana juntos). Protótipo para uso
pessoal do Zander, não para publicar nas lojas por enquanto.

Responda sempre em **português**. O Zander está aprendendo Supabase: explique
os conceitos do Supabase (RLS, Realtime, políticas, funções SQL) quando eles
aparecerem pela primeira vez, de forma breve.

## Requisitos (da spec original)

- Várias listas salvas por usuário, por tipo: mercado, açougue, feira, padaria etc.
- Itens e produtos ficam salvos (tabela `products` = catálogo pessoal para reaproveitar).
- Uma lista pode ser compartilhada com várias pessoas, não só duas.
- Quem cria a lista é o dono e é o único que pode compartilhar.
- Mudanças de um membro aparecem para os outros (tempo real).
- Login só com conta Google.
- Deve ser possível adicionar itens sem internet; ao reconectar, sincroniza.

## Plano aprovado

1. **[feito]** Fundação: projeto Flutter, esquema Supabase com RLS, login Google.
   Testado no celular Android do Zander em 2026-10-11.
2. **[feito]** Listas e itens online: criar/renomear/apagar listas por categoria;
   adicionar, editar, marcar e apagar itens; atualização em tempo real via
   Supabase Realtime entre membros. Inclui autocompletar pelo catálogo
   `products`. Testado no celular em 2026-10-11.
3. **[feito]** Compartilhamento: dono convida pelo e-mail da conta Google (função SQL
   `share_list`), remove membros; membros veem listas compartilhadas e podem sair.
   Testado com dois celulares em tempo real em 2026-10-11.
4. **[feito]** Modo offline: banco SQLite local (drift) com fila de sincronização própria;
   itens criados offline sincronizam ao reconectar. Feito em 6 fases (A a F),
   testado com dois celulares em 2026-10-12.

Plano concluído. Ideias para depois (nada aprovado): sincronização com o app
fechado (WorkManager), tela para gerenciar o catálogo de produtos, participantes
disponíveis offline, iOS.

## Decisões técnicas

- **Backend:** Supabase. Esquema em `supabase/migrations/` (aplicado manualmente
  no SQL Editor do Supabase; novas mudanças viram um novo arquivo numerado, ex.
  `0002_...sql`, e o Zander roda no SQL Editor).
- **Pensado para offline desde já:** IDs são UUID gerados no cliente; tabelas
  sincronizáveis têm `updated_at` (trigger no servidor) e `deleted_at`
  (exclusão suave). Ao apagar itens/listas no app, prefira marcar `deleted_at`.
- **RLS:** membros de uma lista leem/escrevem seus itens; só o dono altera,
  apaga ou compartilha a lista. Funções auxiliares `is_list_member`,
  `is_list_owner`, `shares_a_list_with` (security definer). O dono entra em
  `list_members` automaticamente por trigger ao criar a lista.
- **Login:** `google_sign_in` 7.x (fluxo nativo, `GoogleSignIn.instance.initialize`
  + `authenticate()`), troca do ID token por sessão com
  `supabase.auth.signInWithIdToken`.
- **Configuração:** `config.json` (fora do Git) lido com
  `--dart-define-from-file=config.json`; chaves em `lib/config.dart`.
  Usa a *publishable key* do Supabase, não a anon key antiga.
- **Plataforma:** só Android por enquanto (sem client ID iOS).
  Pacote Android: `dev.listacompras.lista_compras`.
- **Estado:** sem biblioteca de gerência de estado, de propósito (o Zander está
  aprendendo). Serviços singleton em `lib/services/` e telas com `StreamBuilder`
  sobre streams do **banco local** (drift), nunca direto do Supabase. Streams são
  criados uma vez no `State`.
- **Offline / sincronização (etapa 4):** a tela lê e grava só no SQLite
  (`lib/data/app_database.dart`: tabelas espelho `LocalLists/Items/Products`, fila
  `OutboxEntries`, marcos `SyncCursors`). `ListsService`, `ItemsService` e
  `ProductsService` gravam a linha local e enfileiram a mudança na mesma transação.
  - **Fila (outbox):** uma entrada por linha (tabela+id); edições seguidas se
    fundem e guardam só os campos alterados (nomes de coluna do servidor), então
    mudanças de outras pessoas em outros campos sobrevivem. Criação = `upsert` por
    UUID (reenviar não duplica); edição = `update` só dos campos. `revision` evita
    perder edição feita durante um envio (`markSent` deixa só o que mudou).
  - **`SyncService`** (`lib/services/sync_service.dart`): `push` (envia a fila em
    ordem, uma execução por vez; sem rede não conta tentativa; rejeição definitiva
    — SQLSTATE 22/23/42/P0, PGRST1xx/2xx — vira falha; erros passageiros contam até
    10) e `pull` por tabela (remove o que o servidor não mostra mais, busca o que mudou
    desde o marco `updated_at` com 5 min de sobreposição e busca linhas que ficaram
    visíveis, ex. convite para lista antiga). Linhas com entrada na fila (inclusive
    falhas) nunca são sobrescritas nem apagadas pela busca. Disparos do envio: após
    cada alteração (400 ms), ao abrir, ao voltar ao app, ao reconectar
    (`connectivity_plus`) e a cada 30 s.
  - **Realtime é só aviso.** O conteúdo de eventos nunca é aplicado: ele dispara
    `pull` (REST), onde a RLS decide o que o usuário vê. Motivo: o `.stream()` do
    supabase_flutter aplica `INSERT/UPDATE` sem checar nada, e listas de outro
    usuário apareceram no celular da esposa do Zander (2026-10-12). Não voltar a
    usar `.stream()` como fonte de dados (a tela de participantes ainda usa, mas
    só lê membros de listas já visíveis).
  - **Interface:** `SyncStatusBanner` (sem conexão, pendências, falhas) e
    `SyncIssuesScreen` (tentar de novo / descartar; descartar desfaz a mudança local).
  - **Conta:** sair apaga o banco local (avisa se houver pendências); o banco é
    carimbado com o usuário (`db_owner`) e limpo se outra conta entrar.
  - **Offline só para** listas, itens e catálogo. Convidar/remover/sair e ver
    participantes exigem internet.
  - Datas locais são texto ISO (`build.yaml`), para manter a ordem de criação.
    `app_database.g.dart` é gerado e **está no Git**; ao mudar tabelas rode
    `dart run build_runner build`. Mudar tabelas exige subir `schemaVersion` e
    escrever migração.
- **Itens:** adicionar abre o diálogo "Novo item" (nome, quantidade, unidade,
  observação); cancelar não cria o item. Sem quantidade, quantidade+unidade ficam
  ocultas na lista. A unidade padrão de cada produto no catálogo é a última usada.
  A unidade é escolhida num dropdown (`MeasureUnit` em `lib/models/measure_unit.dart`:
  un, kg, g, L, mL, dz, pct, cx, m); no banco continua texto (grava-se o símbolo), então
  incluir unidades não exige migração. Unidades antigas digitadas à mão são
  padronizadas se reconhecidas ("Kg" vira "kg") e preservadas se não ("lata").
  O diálogo é `lib/widgets/item_dialog.dart`.
  O catálogo `products` é lido do banco local ao abrir uma lista (é pessoal, sem Realtime).
- **Compartilhamento:** tela de participantes (`members_screen.dart`), acessível
  pelo ícone de grupo na lista e pelo menu de três pontinhos na tela inicial
  (dono: "Compartilhar"; demais: "Participantes", onde podem sair). Convite via
  RPC `share_list`; remover e sair são o mesmo DELETE em `list_members`.
  Convidar só insere em `list_members` e não altera `lists`; por isso o aviso
  Realtime de `list_members` também dispara a busca de listas e itens. Quem é
  removido (ou tem a lista apagada) com a lista aberta volta sozinho para a tela
  inicial (`ListsService.watchList` emite `null`).

## Ambiente do Zander

- Windows, PowerShell. Roda o app com:
  `flutter run --dart-define-from-file=config.json`
- Guia de configuração do Supabase/Google: `docs/GUIA_SUPABASE.md`.

## Antes de entregar

- `flutter analyze` sem problemas e `flutter test` passando (testes não precisam
  de rede; `test/support/` tem servidores falsos: `FakeGateway` para falhas
  pontuais e `InMemoryServer` para cenários de dois aparelhos).
- Mexeu em sincronização, banco local ou compartilhamento: rodar também o
  roteiro manual `docs/ROTEIRO_TESTES_OFFLINE.md` (dois celulares).
- Hot reload não basta para mudar `late final`/`initState` nem dependências
  nativas: pare e rode de novo (F5).
- Mudanças de banco: novo arquivo em `supabase/migrations/` e explicar ao
  Zander o que rodar no SQL Editor.
