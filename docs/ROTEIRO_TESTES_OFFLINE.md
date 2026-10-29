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

## 8. Importar e exportar o catálogo

Detalhes dos formatos em [IMPORTAR_CATALOGO.md](IMPORTAR_CATALOGO.md).

1. Passe `docs/catalogo_inicial.csv` para o celular. No catálogo: ⋮ → **Importar
   catálogo…** → **Escolher arquivo**. A pré-visualização mostra os produtos novos
   e quais já existem (ex.: Arroz, Alcatra). Nada é gravado ainda.
2. Toque em **Importar N produtos**: eles aparecem no catálogo, em ordem alfabética.
3. Importe o mesmo arquivo de novo: "Nada novo para importar".
4. **Colar texto**: cole algumas linhas (com e sem `;unidade`) e confira a
   pré-visualização, incluindo uma linha repetida e uma com unidade desconhecida.
5. Escolha um arquivo que não é texto (um PDF ou `.xlsx`): mensagem clara, sem travar.
6. **Copiar como texto** no celular A e **Colar texto** no celular B (ou **Exportar
   para arquivo…** e importar o arquivo): só entram os produtos que B não tinha.
7. Importe com internet desligada: a faixa mostra as alterações pendentes e tudo
   sobe ao reconectar (em poucas requisições, não uma por produto).

## 9. Aviso de lista compartilhada e WhatsApp

1. Em A, convide B para uma lista. Aparece o diálogo "Lista compartilhada" com
   **Avisar pelo WhatsApp**: ele abre o WhatsApp com a mensagem pronta (escolha o
   contato). Teste também **Agora não**.
2. Em B (app aberto ou ao abrir), aparece no topo da tela inicial o cartão
   "Nova lista compartilhada: ..." com o nome de A.
3. Tocar no cartão abre a lista e o aviso some; em outra lista, o **X** dispensa.
   Fechar e abrir o app: o aviso não volta.
4. Em A, remova B e convide de novo: o aviso volta a aparecer em B.
5. Listas que B já tinha antes desta versão do app não geram aviso.

## 10. Reordenar itens (puxador de 6 pontinhos)

1. Os itens que já existiam aparecem na mesma ordem de antes da atualização.
2. Arraste um item pelo puxador (6 pontinhos, à esquerda) para cima, para baixo,
   para o topo e para o fim. Ao soltar, ele fica no lugar, sem "pular".
3. Tocar no item ainda edita; deslizar para a esquerda ainda apaga; arrastar fora
   do puxador não reordena (só rola a lista).
4. Marque um item: ele vai para "N itens marcados" (toque no cabeçalho para
   recolher/abrir). Desmarque: ele volta ao lugar onde estava.
5. Com a lista compartilhada aberta nos dois celulares, reordene em A: a nova
   ordem aparece em B. Ao mesmo tempo, arraste em B: a lista não pula na mão.
6. Modo avião em A e B, cada um reordena; ao reconectar, os dois terminam com a
   mesma ordem.
7. Item novo vai para o fim da lista.

## 11. Última atualização na tela inicial

Antes: rode `supabase/migrations/0004_quem_atualizou.sql` no SQL Editor.

1. Cada lista mostra "Última atualização dd/mm/aaaa hh:mm por ...". Listas e itens
   de antes da migração mostram o criador/dono como autor.
2. Em A, adicione, marque e apague um item: a data e hora da lista mudam na hora,
   com "por você".
3. Em B (lista compartilhada), depois de sincronizar, aparece o nome de A como autor.
   Faça uma alteração em B: em A passa a aparecer o nome de B.
4. Renomear a lista também conta.
5. Modo avião em A: a alteração atualiza a data na hora; o nome de outra pessoa que
   ainda não foi buscado fica de fora (só a data), sem erro.

## Se algo falhar

O Debug Console (com o celular conectado e `flutter run`) mostra linhas
`SyncService: ...`: erros de rede, rejeições do servidor (com o código) e
remoções de linhas que o servidor não mostra mais.
