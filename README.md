# Lista de Compras

App Flutter (Android e iOS) para compartilhar listas de compras de supermercado
entre várias pessoas, com sincronização em tempo real via Supabase.

## Estado atual

- [x] Etapa 1: projeto Flutter, banco Supabase com regras de segurança, login com Google
- [ ] Etapa 2: listas e itens online, em tempo real
- [ ] Etapa 3: compartilhamento pelo e-mail da conta Google
- [ ] Etapa 4: modo offline com sincronização ao reconectar

## Como rodar

1. Siga o [guia de configuração do Supabase](docs/GUIA_SUPABASE.md).
2. `cp config.example.json config.json` e preencha as chaves.
3. `flutter run --dart-define-from-file=config.json`

## Estrutura

```
lib/
  config.dart              chaves lidas do config.json
  main.dart                inicialização e escolha entre login e tela inicial
  services/auth_service.dart  login Google + Supabase
  screens/                 telas
supabase/migrations/       SQL do banco (tabelas, regras RLS, funções)
docs/                      guias
```
