# Lista de Compras

App Flutter (Android) para compartilhar listas de compras de supermercado
entre várias pessoas, com sincronização em tempo real via Supabase e
funcionamento sem internet.

## Estado atual

- [x] Etapa 1: projeto Flutter, banco Supabase com regras de segurança, login com Google
- [x] Etapa 2: listas e itens, com autocompletar pelo catálogo de produtos
- [x] Etapa 3: compartilhamento pelo e-mail da conta Google
- [x] Etapa 4: modo offline (SQLite local) com sincronização ao reconectar

## Como rodar

1. Siga o [guia de configuração do Supabase](docs/GUIA_SUPABASE.md).
2. `cp config.example.json config.json` e preencha as chaves.
3. `flutter run --dart-define-from-file=config.json` (ou F5 no VS Code, que já
   usa `.vscode/launch.json` local).

## Testes

- `flutter analyze` e `flutter test` (sem rede nem celular).
- Roteiro manual com dois celulares: [docs/ROTEIRO_TESTES_OFFLINE.md](docs/ROTEIRO_TESTES_OFFLINE.md).

## Como funciona o offline (resumo)

A tela lê e grava sempre no SQLite do celular (drift). Cada mudança também entra
numa fila de pendências; o `SyncService` envia a fila ao Supabase e traz o que
mudou lá. O Realtime só avisa que algo mudou; os dados vêm de consultas com as
regras de segurança (RLS) do servidor. Detalhes em `CLAUDE.md`.

## Estrutura

```
lib/
  config.dart                chaves lidas do config.json
  main.dart                  inicialização e escolha entre login e tela inicial
  data/app_database.dart     banco local (drift): tabelas espelho, fila de pendências, marcos
  models/                    ShoppingList, Item, Product, Member
  services/                  auth, listas, itens, produtos, participantes e sincronização
  screens/                   telas (listas, itens, participantes, catálogo, problemas de sync)
  widgets/                   diálogos, seletor de unidade e faixa de estado da sincronização
  utils/                     texto sem acentos para ordenar e buscar
supabase/migrations/         SQL do banco (tabelas, regras RLS, funções)
test/                        testes (support/ tem o servidor falso usado nos testes)
docs/                        guias, roteiro de testes e catalogo_inicial.csv (importável)
```

O arquivo `lib/data/app_database.g.dart` é gerado e fica no Git. Ao mudar as
tabelas em `app_database.dart`, rode `dart run build_runner build`.
