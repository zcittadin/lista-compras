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
3. **[próxima]** Compartilhamento: dono convida pelo e-mail da conta Google (função SQL
   `share_list` já existe), remove membros; membros veem listas compartilhadas e podem sair.
4. Modo offline: banco SQLite local (drift) com fila de sincronização própria;
   itens criados offline sincronizam ao reconectar.

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
  aprendendo). Serviços singleton em `lib/services/` (`ListsService`,
  `ItemsService`, `ProductsService`) e telas com `StreamBuilder` sobre
  `supabase.from(...).stream(...)`. O stream é criado uma vez no `State`.
  O stream não filtra `deleted_at`: os serviços descartam essas linhas no cliente.
- **Itens:** adicionar abre o diálogo "Novo item" (nome, quantidade, unidade,
  observação); cancelar não cria o item. Sem quantidade, quantidade+unidade ficam
  ocultas na lista. A unidade padrão de cada produto no catálogo é a última usada.
  Catálogo `products` só é carregado ao abrir uma lista (sem Realtime, é pessoal).

## Ambiente do Zander

- Windows, PowerShell. Roda o app com:
  `flutter run --dart-define-from-file=config.json`
- Guia de configuração do Supabase/Google: `docs/GUIA_SUPABASE.md`.

## Antes de entregar

- `flutter analyze` sem problemas e `flutter test` passando.
- Mudanças de banco: novo arquivo em `supabase/migrations/` e explicar ao
  Zander o que rodar no SQL Editor.
