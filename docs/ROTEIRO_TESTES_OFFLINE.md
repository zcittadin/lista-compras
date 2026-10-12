# Roteiro de testes manuais: offline e compartilhamento

Para rodar antes de entregar mudanças que mexam na sincronização, no banco
local ou no compartilhamento. Precisa de **dois celulares** com contas Google
diferentes (chamados aqui de **A**, o dono, e **B**) e ambos com o app
instalado de uma compilação completa (não só hot reload).

Os cenários principais também existem como testes automáticos em
`test/services/two_devices_test.dart`. Este roteiro cobre o que eles não
alcançam: tela, Realtime de verdade e rede real.

## Preparação

- Os dois celulares logados e com o app aberto, com internet.
- Em A, crie duas listas com alguns itens. Anote os nomes.

## 1. Tempo real e compartilhamento

1. Em A: lista → ícone de grupo (ou menu ⋮ → Compartilhar) → e-mail de B.
2. B vê a lista em instantes, com os itens.
3. Adicione, marque e apague itens nos dois lados: aparece no outro sem recarregar.
4. **Privacidade:** B deve ver **somente** as listas compartilhadas com ele.
   Apague uma lista compartilhada em A: some em B, e nenhuma lista não
   compartilhada de A aparece em B.
5. Em A, remova B (Participantes). Com a lista aberta em B, ele volta para a
   tela inicial com o aviso "não está mais disponível para você".
6. Convide B para uma lista **antiga** (com itens). B vê a lista com todos os itens.

## 2. Offline

1. Em A, ligue o **modo avião**. A faixa "Sem conexão" aparece.
2. Crie uma lista, adicione itens, marque um, edite outro.
   A faixa passa a mostrar "N alterações aguardando envio".
3. Feche o app **pelo menu de recentes** e abra de novo ainda em modo avião:
   a lista e os itens continuam lá, sem mensagem de erro.
4. Desligue o modo avião. Em até ~30 s (normalmente em poucos segundos) a
   faixa some e tudo aparece no Supabase (Table Editor) e em B.
5. Confira que **não duplicou** nada.

## 3. Conflito entre aparelhos

1. Com uma lista compartilhada, ligue o modo avião em A e **marque** um item.
2. Em B (online), **renomeie** esse mesmo item e salve.
3. Desligue o modo avião em A. Nos dois celulares o item deve ficar
   **marcado e com o novo nome**.

## 4. Falhas do servidor

1. Em B, ligue o modo avião (a lista compartilhada continua visível).
2. Em A, remova B da lista.
3. Em B, edite um item dessa lista e desligue o modo avião.
4. A faixa vermelha "1 alteração não pôde ser enviada" aparece. Toque em **Ver**:
   a explicação deve falar em permissão/acesso.
5. Teste **Descartar** (a lista some do B) e, num novo caso, **Tentar de novo**.

## 5. Participantes sem internet

Em modo avião, abra Participantes: mensagem "Sem conexão…" com botão
**Tentar de novo** (sem texto técnico).

## 6. Sair da conta

1. Em modo avião, faça uma alteração e toque em **Sair**: o app avisa que há
   alterações não enviadas.
2. Cancele, volte a ter internet, espere enviar e saia. Entre com **outra**
   conta: nada da conta anterior pode aparecer.

## 7. Catálogo de produtos

1. Ícone de caixa na tela inicial → **Catálogo de produtos**.
2. Crie, edite (nome e unidade) e apague por arraste; use **Desfazer** logo após apagar.
3. Tente criar/renomear para um nome que já existe (mesmo com outra caixa ou com
   emoji, ex. "arroz" × "Arroz" × "Arroz 🍚"): o diálogo avisa, cita o produto
   que já existe e continua aberto.
4. Apague "Arroz" do catálogo e adicione um item "Arroz" numa lista: o produto
   volta ao catálogo.
5. Em modo avião, edite o catálogo: a faixa mostra as alterações pendentes e
   tudo sobe ao reconectar. (Com o mesmo usuário em dois celulares, a mudança
   aparece no outro ao abri-lo ou voltar ao app.)
6. A busca ignora acentos ("acucar" acha "Açúcar") e a ordem alfabética
   também (Açúcar antes de Arroz).

## Se algo falhar

O Debug Console (com o celular conectado e `flutter run`) mostra linhas
`SyncService: ...`: erros de rede, rejeições do servidor (com o código) e
remoções de linhas que o servidor não mostra mais.
