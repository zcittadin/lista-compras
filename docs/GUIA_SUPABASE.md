# Guia: configurando o Supabase e o login com Google

Este guia leva você do zero até o app abrindo com login Google funcionando.
Faça na ordem; cada passo usa algo do anterior.

> **Conceitos rápidos**
> - **Supabase** é um banco PostgreSQL na nuvem com login, API e tempo real prontos.
>   O app conversa direto com o banco, sem um servidor próprio no meio.
> - **RLS (Row Level Security)** são regras escritas no próprio banco que decidem
>   quais linhas cada usuário pode ver ou alterar. Por isso é seguro o app falar
>   direto com o banco: mesmo que alguém tente, o banco recusa o que não é dele.
> - **Publishable key** é a chave pública do projeto. Pode ficar dentro do app,
>   porque sozinha ela não dá acesso a nada que as regras RLS não permitam.
>   Já a **secret key** (antiga *service_role*) nunca deve ir para o app.

---

## 1. Criar o projeto no Supabase

1. Crie uma conta em <https://supabase.com> (pode entrar com o GitHub).
2. Clique em **New project**.
   - **Name:** `lista-compras`
   - **Database password:** gere uma e guarde num gerenciador de senhas.
   - **Region:** *South America (São Paulo)*, para ficar mais rápido no Brasil.
3. Aguarde o projeto ficar pronto (leva uns 2 minutos).
4. Vá em **Project Settings → API Keys** e anote:
   - **Project URL** (algo como `https://abcd1234.supabase.co`, aparece em *Data API*)
   - **Publishable key** (começa com `sb_publishable_`)

## 2. Criar as tabelas e as regras de segurança

1. No menu lateral, abra **SQL Editor → New query**.
2. Copie todo o conteúdo de [`supabase/migrations/0001_esquema_inicial.sql`](../supabase/migrations/0001_esquema_inicial.sql), cole e clique em **Run**.
3. Abra **Table Editor**: devem aparecer `profiles`, `lists`, `list_members`, `items` e `products`, cada uma com o selo *RLS enabled*.

O que esse arquivo cria:

| Tabela | Para que serve |
|---|---|
| `profiles` | Um registro por pessoa, criado sozinho no primeiro login. |
| `lists` | As listas (mercado, açougue, feira, padaria...). Quem cria é o dono. |
| `list_members` | Quem tem acesso a cada lista. O dono entra automaticamente. |
| `items` | Os itens de cada lista, com quantidade e se já foi pego. |
| `products` | Seu catálogo de produtos salvos, para reaproveitar. |

E as regras: só membros veem e editam os itens de uma lista, só o dono renomeia,
apaga ou compartilha a lista, e qualquer membro pode sair dela.

## 3. Criar as credenciais no Google Cloud

O login com Google precisa de três "IDs de cliente": um **Web** (que o Supabase
usa para validar), um **Android** e um **iOS**.

1. Acesse <https://console.cloud.google.com> e crie um projeto chamado `lista-compras`.
2. Vá em **APIs e serviços → Tela de permissão OAuth** (ou *Google Auth Platform*):
   - Tipo de usuário: **Externo**.
   - Preencha nome do app e seu e-mail.
   - Em **Público-alvo / Usuários de teste**, adicione o seu e-mail e o de quem
     vai testar com você. Enquanto o app estiver "em teste", só essas contas entram.
3. Vá em **Credenciais → Criar credenciais → ID do cliente OAuth** três vezes:

   **a) Aplicativo da Web**
   - Nome: `Supabase`
   - Em *URIs de redirecionamento autorizados*, cole a *Callback URL* que aparece
     no Supabase em **Authentication → Sign In / Providers → Google**.
     Nessa tela do Supabase, os campos *Client IDs* e *Client Secret* ainda estão
     em branco: é normal, eles são preenchidos no passo 4 com o que o Google gerar agora.
   - Anote o **ID do cliente** e a **Chave secreta do cliente**.

   **b) Android**
   - Nome do pacote: `dev.listacompras.lista_compras`
   - Impressão digital SHA-1: no computador onde você roda o app, execute
     ```bash
     keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
     ```
     e copie a linha `SHA1`. (No Windows o arquivo fica em `%USERPROFILE%\.android\debug.keystore`.)

   **c) iOS** (só se for testar no iPhone)
   - ID do pacote: `dev.listacompras.listaCompras`
   - Anote o **ID do cliente** e o **Esquema de URL do iOS** (o ID invertido, que
     começa com `com.googleusercontent.apps.`).

## 4. Ligar o Google no Supabase

1. No Supabase: **Authentication → Sign In / Providers → Google**, ative.
2. **Client IDs:** cole o ID Web e, se tiver, o ID iOS, separados por vírgula
   (o Web primeiro).
3. **Client Secret:** a chave secreta do cliente Web.
4. Ative **Skip nonce checks**. É necessário para o login nativo no iPhone.
5. Salve.

## 5. Configurar o app

1. Na pasta do projeto, copie o exemplo:
   ```bash
   cp config.example.json config.json
   ```
2. Preencha o `config.json` com a URL, a publishable key e os IDs Web e iOS.
   Esse arquivo fica fora do Git.
3. **Só para iPhone:** em `ios/Runner/Info.plist`, antes do último `</dict>`, adicione
   (trocando pelos seus valores):
   ```xml
   <key>GIDClientID</key>
   <string>SEU-ID-IOS.apps.googleusercontent.com</string>
   <key>CFBundleURLTypes</key>
   <array>
     <dict>
       <key>CFBundleURLSchemes</key>
       <array>
         <string>com.googleusercontent.apps.SEU-ID-INVERTIDO</string>
       </array>
     </dict>
   </array>
   ```

## 6. Rodar e testar

```bash
flutter pub get
flutter run --dart-define-from-file=config.json
```

1. Toque em **Entrar com Google** e escolha sua conta.
2. Deve aparecer "Olá, seu nome!".
3. No Supabase, abra **Table Editor → profiles**: sua linha deve estar lá.
4. Peça para a outra pessoa entrar também, para o perfil dela existir quando
   formos compartilhar listas na etapa 3.

## Problemas comuns

| Sintoma | Causa provável |
|---|---|
| Tela "Configuração ausente" | Faltou o `--dart-define-from-file=config.json` ou o arquivo está incompleto. |
| Erro `[16] Account reauth failed` ou login fecha sozinho no Android | SHA-1 ou nome do pacote errados no ID Android, ou seu e-mail não está nos usuários de teste. |
| `Unacceptable audience in id_token` | O ID Web não está no campo *Client IDs* do Supabase, ou o `GOOGLE_WEB_CLIENT_ID` está errado. |
| `Passed nonce and nonce in id_token should either both exist or not` (iPhone) | Faltou ativar *Skip nonce checks*. |
