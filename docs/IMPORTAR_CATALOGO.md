# Importar e exportar o catálogo de produtos

No app: tela **Catálogo de produtos** (ícone de caixa na tela inicial) → menu
**⋮** → **Importar catálogo…**, **Exportar para arquivo…** ou **Copiar como texto**.

## Para montar o catálogo inicial

O arquivo [`catalogo_inicial.csv`](catalogo_inicial.csv) tem cerca de 130
produtos comuns de supermercado, farmácia e limpeza, já com a unidade. Para usar:

1. Passe o arquivo para o celular (Drive, WhatsApp, e-mail ou cabo USB).
2. No app: Catálogo → ⋮ → **Importar catálogo…** → **Escolher arquivo**.
3. Confira a pré-visualização (o que é novo, o que já existe) e toque em **Importar**.

Dá para editar o arquivo antes: apague o que não usa e acrescente o que falta.

## Formatos aceitos

Um produto por linha, com a unidade opcional. Qualquer um destes serve:

**CSV com cabeçalho** (o que o Excel e o Planilhas Google exportam):
```
nome;unidade
Arroz;kg
Leite;L
Sal
```

**Texto simples**, um nome por linha:
```
Arroz
Leite
Sal
```

- O separador pode ser `;`, vírgula ou tab. O app descobre sozinho.
- O cabeçalho é opcional. Se houver, as colunas podem estar em qualquer ordem
  e ter outras colunas (que são ignoradas). Reconhece `nome`, `produto`, `item`
  e `unidade`, `medida`.
- **Unidades:** `un, kg, g, L, mL, dz, pct, cx, m`. Também entende "quilo",
  "litro", "pacote", "unidade", "dúzia", "mt", "und" etc. Uma unidade que o app
  não conhece é ignorada (o produto entra sem unidade) e a pré-visualização avisa.
- Nomes com **emoji** são mantidos ("Arroz 🍚"). Para decidir se um produto já
  existe, o app ignora maiúsculas e emojis (mas não acentos).

## Planilha do Excel ou do Google

O app não lê `.xlsx` diretamente. Salve como CSV:

- **Excel:** Arquivo → Salvar como → *CSV UTF-8 (delimitado por vírgulas)* ou *CSV (separado por ponto e vírgula)*.
- **Planilhas Google:** Arquivo → Fazer download → *Valores separados por vírgula (.csv)*.

Se o arquivo vier em "CSV" comum do Excel em português (codificação Windows-1252),
o app reconhece e avisa na pré-visualização para você conferir os acentos.

## Acentos estranhos ("CafÃ©", "BrÃ³colis")?

Isso acontece quando alguma ferramenta (Excel, PowerShell...) lê o arquivo
como ANSI e o salva de novo como UTF-8: o texto fica corrompido **dentro do
arquivo**. O app reconhece esse defeito e conserta sozinho, linha a linha, e a
pré-visualização avisa ("N linhas tinham os acentos corrompidos… foram
corrigidas"). Confira a lista antes de importar.

Para evitar o problema, não abra e salve o `.csv` no Excel: passe o arquivo
como está (Drive, e-mail, USB). Se precisar editar, use um editor de texto
(VS Code, Bloco de Notas) salvando em **UTF-8**.

Se produtos com acento quebrado já entraram no catálogo (importados antes desse
conserto), apague-os no Supabase (SQL Editor). Veja primeiro quais são e depois
marque como apagados (troque o e-mail pelo da conta certa):

```sql
select p.name from public.products p
join public.profiles u on u.id = p.owner_id
where u.email = 'seu@email.com' and p.deleted_at is null and p.name ~ '[ÃÂ]';

update public.products p set deleted_at = now()
from public.profiles u
where u.id = p.owner_id and u.email = 'seu@email.com'
  and p.deleted_at is null and p.name ~ '[ÃÂ]';
```

Depois importe o arquivo de novo.

## Colar texto

Em **Importar catálogo… → Colar texto** dá para colar uma lista (por exemplo, copiada
do WhatsApp ou de uma nota). O botão de colar do campo traz o que está na área
de transferência.

## Passar o catálogo para outra pessoa

Quem já tem o catálogo pronto pode compartilhá-lo:

1. **Copiar como texto** e enviar a mensagem (ou **Exportar para arquivo…** e
   enviar o `.csv`).
2. A outra pessoa cola em **Importar catálogo… → Colar texto** (ou escolhe o arquivo).
3. Produtos que ela já tem são ignorados; só os novos entram.

## Limites

- Arquivo de até 1 MB e 2.000 linhas.
- Nome de produto com até 120 caracteres (linhas maiores são ignoradas e listadas).
- Produtos repetidos no arquivo entram uma vez só (vale a primeira linha).
- Importar de novo o mesmo arquivo não duplica nada.
