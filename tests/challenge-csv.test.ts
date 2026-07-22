import assert from "node:assert/strict";
import test from "node:test";
import { parseChallengeCsv } from "../src/features/challenges/challenge-csv.ts";

const HEADER = "titulo,enunciado,alternativa_a,alternativa_b,alternativa_c,alternativa_d,correta";

test("valida todas as linhas e preserva vírgulas e aspas escapadas", () => {
  const result = parseChallengeCsv([
    HEADER,
    '"Título, especial","Qual é a resposta?","Opção ""A""","B","C","D","A"',
  ].join("\r\n"));

  assert.deepEqual(result.fileErrors, []);
  assert.equal(result.invalidCount, 0);
  assert.equal(result.rows[0]?.title, "Título, especial");
  assert.equal(result.rows[0]?.alternatives[0], 'Opção "A"');
});

test("produz relatório por linha sem aceitar importação parcial", () => {
  const result = parseChallengeCsv([
    HEADER,
    '"Válido","Pergunta?","A","B","C","D","A"',
    '"","","","B","C","D","X"',
  ].join("\n"));

  assert.equal(result.validCount, 1);
  assert.equal(result.invalidCount, 1);
  assert.equal(result.rows[1]?.line, 3);
  assert.ok((result.rows[1]?.errors.length ?? 0) >= 4);
});

test("marca todas as ocorrências duplicadas", () => {
  const row = '"Duplicado","Pergunta?","A","B","C","D","B"';
  const result = parseChallengeCsv([HEADER, row, row].join("\n"));

  assert.equal(result.invalidCount, 2);
  assert.match(result.rows[0]?.errors[0] ?? "", /linha 3/);
  assert.match(result.rows[1]?.errors[0] ?? "", /linha 2/);
});

test("aceita quebra de linha dentro de campo entre aspas", () => {
  const result = parseChallengeCsv([
    HEADER,
    '"Multilinha","Primeira linha\nSegunda linha","A","B","C","D","D"',
  ].join("\n"));

  assert.equal(result.invalidCount, 0);
  assert.equal(result.rows[0]?.prompt, "Primeira linha\nSegunda linha");
});

test("rejeita cabeçalho diferente do modelo", () => {
  const result = parseChallengeCsv("titulo,pergunta,a,b,c,d,resposta\nTeste,Pergunta,A,B,C,D,A");
  assert.match(result.fileErrors[0] ?? "", /Cabeçalho inválido/);
});
