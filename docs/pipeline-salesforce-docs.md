# Pipeline CI/CD Salesforce — Documentação Completa

## Visão Geral

Este repositório utiliza 6 workflows do GitHub Actions que formam um pipeline completo de CI/CD para Salesforce, baseado no modelo de **Release Branch**.

Cada squad trabalha de forma independente — abrindo PRs, validando em CI, deployando em UAT, homologando e aprovando GMUD no seu próprio ritmo. Quando tudo está aprovado, o PR é mergeado na release branch. No dia do deploy, o Release Manager mergeia a release branch na `main`, disparando o deploy para produção com todas as features da release de uma só vez.

```
Squad A ──► PR → release/2026-05-23 ──► CI → UAT → homologa → GMUD → merge
Squad B ──► PR → release/2026-05-23 ──► CI → UAT → homologa → GMUD → merge
Squad C ──► PR → release/2026-05-23 ──► CI → UAT → homologa → GMUD → merge

                    (cada squad no seu ritmo)

Dia do deploy:
Release Manager ──► PR release/2026-05-23 → main
                ──► Aprova e mergeia
                ──► Tag automática (aprovador + data + GMUDs)
                ──► Deploy PRD dispara automaticamente
```

---

## Modelo Release Branch

### Convenção de nomes

As release branches seguem o padrão `release/YYYY-MM-DD`, onde a data representa o dia planejado para o deploy em produção.

Exemplos: `release/2026-05-23`, `release/2026-06-10`, `release/hotfix-2026-05-24`

### Ciclo de vida

1. **Criação**: O Release Manager (ou Tech Lead) cria a release branch a partir da `main`
2. **Acumulação**: Squads mergeiam seus PRs na release branch conforme aprovados
3. **Deploy**: No dia planejado, Release Manager mergeia a release branch na `main`
4. **Encerramento**: A release branch é deletada após o merge

### Vantagens

- Cada squad segue seu próprio ritmo de CI, UAT e GMUD
- Homologação individual por squad — cada time testa sua feature
- Uma única operação de deploy para produção agrupa todas as features
- Conflitos entre features são detectados durante o merge na release branch
- Reduz a quantidade de deploys e notificações de rebase

---

## 1. CI - Validate PR (`ci-validate.yml`)

### O que faz

Executa um dry-run (validação sem deploy real) na org CI com testes Apex locais. Garante que o código compila e os testes passam antes de qualquer deploy.

### Gatilho

```yaml
on:
  pull_request:
    branches: ['release/*']
    paths: ['force-app/**']
    types: [opened, synchronize, reopened]
```

| Evento | Quando dispara |
|--------|----------------|
| `opened` | Dev abre um PR apontando para `release/*` |
| `synchronize` | Dev faz push de novos commits na branch do PR |
| `reopened` | PR que foi fechado é reaberto |

Só dispara se houver alterações dentro de `force-app/`.

### Como é disparado

Automaticamente. O dev não precisa fazer nada além de abrir o PR ou fazer push na branch.

### O que acontece

1. Faz checkout do código
2. Instala o Salesforce CLI
3. Autentica na org CI usando o secret `SF_CI_AUTH_URL`
4. Executa `sf project deploy validate` com `RunLocalTests` (dry-run)
5. Se falhar, comenta no PR com a mensagem de erro

### Pré-requisitos

- Secret `SF_CI_AUTH_URL` configurado

### Resultado

- **Passou**: Status check verde "Validate in CI Org"
- **Falhou**: Comentário no PR com `❌ CI Validation falhou`

---

## 2. Deploy UAT (`deploy-uat.yml`)

### O que faz

Deploya a feature branch na org UAT para homologação. Só executa quando o PR já passou no CI e tem pelo menos 2 aprovações de code review.

### Gatilho

```yaml
on:
  pull_request_review:
    types: [submitted]
```

Com condição adicional: só prossegue se o review for aprovação E o PR apontar para `release/*`.

| Evento | Quando dispara |
|--------|----------------|
| `submitted` | Alguém submete um review no PR |

### Como é disparado

Automaticamente quando um reviewer aprova o PR:

1. Primeiro reviewer aprova → workflow roda, detecta que falta 1 aprovação → não deploya
2. Segundo reviewer aprova → workflow roda, detecta CI ok + 2 aprovações → deploya em UAT

### O que acontece

1. Verifica se o CI passou (status check "Validate in CI Org" = SUCCESS)
2. Conta aprovações únicas (mínimo 2)
3. Faz checkout da feature branch
4. Verifica se a branch está atualizada com a release branch (sem commits atrás)
5. Se a branch estiver desatualizada, bloqueia e comenta instruções de rebase
6. Autentica na org UAT usando `SF_UAT_AUTH_URL`
7. Executa `sf project deploy start` com `RunLocalTests`
8. Comenta no PR o resultado

### Pré-requisitos

- Secret `SF_UAT_AUTH_URL` configurado
- CI deve ter passado
- Mínimo de 2 aprovações de code review
- Branch atualizada com a release branch

### Resultado

- **Passou**: Comentário `✅ Deploy UAT realizado com sucesso` com próximos passos
- **Falhou**: Comentário `❌ Deploy UAT falhou`
- **Branch desatualizada**: Comentário `⚠️ Deploy UAT bloqueado` com instruções de rebase

---

## 3. GMUD Gate (`gmud-gate.yml`)

### O que faz

Valida que a homologação foi concluída E que uma GMUD aprovada está associada ao PR. Funciona como Required Status Check — o merge na release branch só é liberado quando ambas as labels estão presentes.

### Gatilho

```yaml
on:
  pull_request:
    branches: ['release/*']
    types: [labeled, unlabeled, opened, synchronize]
```

| Evento | Quando dispara |
|--------|----------------|
| `labeled` | Alguém adiciona uma label no PR |
| `unlabeled` | Alguém remove uma label do PR |
| `opened` | PR é aberto |
| `synchronize` | Novo push na branch do PR |

### Como é disparado

Automaticamente, mas depende de ações manuais:

1. Após homologação em UAT, o **QA ou Tech Lead** adiciona a label `homologado` → workflow dispara
2. Após aprovação da GMUD no CoE, o **Release Manager** adiciona a label `GMUD-XXXX` (ex: `GMUD-4821`) → workflow dispara novamente

### O que acontece

1. Lê as labels diretamente do payload do evento
2. Verifica se a label `homologado` está presente
3. Verifica se existe uma label no formato `GMUD-` seguido de números
4. Se ambas presentes, o check passa e o merge na release branch é liberado

### Pré-requisitos

- Label `homologado` no PR
- Label `GMUD-XXXX` no PR (com número real da GMUD)
- Configurar `Validate Homologation & GMUD` como Required Status Check nas branches `release/*`

### Resultado

| Status | Labels presentes |
|--------|-----------------|
| ❌ Falhou | Nenhuma label |
| ❌ Falhou | Só `homologado` |
| ❌ Falhou | Só `GMUD-XXXX` |
| ✅ Passou | `homologado` + `GMUD-XXXX` |

---

## 4. Deploy PRD (`deploy-prd.yml`)

### O que faz

Deploya o código em produção após o merge da release branch na `main`. Executa validate (dry-run) seguido de quick deploy. Cria uma tag de rastreabilidade com o aprovador, data e todas as GMUDs incluídas na release.

### Gatilho

```yaml
on:
  push:
    branches: [main]
    paths: ['force-app/**']
```

| Evento | Quando dispara |
|--------|----------------|
| `push` | Qualquer push na `main` que altere `force-app/` |

Na prática, disparado quando o Release Manager mergeia o PR da release branch na `main`.

### Como é disparado

1. Release Manager cria um PR: `release/2026-05-23` → `main`
2. Release Manager mergeia o PR
3. Push na `main` detectado → workflow inicia
4. Workflow **para** no environment `PRD` e aguarda aprovação
5. Aprovador do environment aprova no GitHub Actions
6. Deploy prossegue

### O que acontece

1. Extrai informações da release: branch, quem mergeou, PRs incluídos, GMUDs
2. Instala Salesforce CLI
3. Autentica na org PRD usando `SF_PRD_AUTH_URL`
4. Executa `sf project deploy validate` (dry-run com testes)
5. Se validação ok, executa `sf project deploy quick` (quick deploy)
6. Cria tag no formato `prd-YYYYMMDD-HHMMSS` com metadados completos da release
7. Comenta no PR da release o resultado do deploy

### Tag de deploy

A tag inclui:

- Release branch (ex: `release/2026-05-23`)
- Quem aprovou/mergeou (o Release Manager)
- Quantidade de PRs incluídos
- Lista de todas as GMUDs
- Data e hora do deploy

### Pré-requisitos

- Secret `SF_PRD_AUTH_URL` configurado
- Environment `PRD` configurado com aprovadores
- Release branch mergeada na `main`

### Resultado

- **Passou**: Tag criada, comentário `🚀 Deploy PRD realizado com sucesso` com tabela de detalhes
- **Falhou**: Comentário `❌ Deploy PRD falhou` com orientação para rollback

---

## 5. Notify Rebase Needed (`notify-rebase.yml`)

### O que faz

Após um merge na release branch, notifica todos os PRs abertos apontando para a mesma release de que precisam fazer rebase.

### Gatilho

```yaml
on:
  push:
    branches: ['release/*']
    paths: ['force-app/**']
```

| Evento | Quando dispara |
|--------|----------------|
| `push` | Merge de um PR de squad na release branch |

### Como é disparado

Automaticamente quando um PR é mergeado na release branch. Não requer ação manual.

### O que acontece

1. Identifica qual PR foi mergeado e em qual release branch
2. Lista todos os PRs abertos apontando para a mesma release branch
3. Comenta em cada PR aberto (exceto o que foi mergeado) com `⚠️ Rebase necessário`
4. Inclui instruções de rebase apontando para a release branch

### Pré-requisitos

Nenhum secret adicional — usa o `GITHUB_TOKEN` padrão.

### Resultado

Cada PR aberto na mesma release recebe um comentário com aviso e instruções de rebase. O deploy-uat bloqueia deploy se a branch não estiver atualizada.

---

## 6. Rollback PRD (`rollback-prd.yml`)

### O que faz

Reverte o merge da release branch na `main`, desfazendo o deploy em produção. Isso reverte a release inteira (todos os PRs que estavam na release). O push do revert dispara automaticamente o Deploy PRD com o código revertido.

### Gatilho

```yaml
on:
  workflow_dispatch:
    inputs:
      pr_number:
        description: 'Número do PR da release branch (ex: 50)'
        required: true
      reason:
        description: 'Motivo do rollback'
        required: true
```

| Evento | Quando dispara |
|--------|----------------|
| `workflow_dispatch` | Execução manual pela interface do GitHub Actions |

### Como é disparado

**Manualmente:**

1. Ir em Actions > Rollback PRD > Run workflow
2. Preencher o número do PR da release branch (o PR `release/* → main`)
3. Preencher o motivo do rollback
4. Clicar em "Run workflow"
5. Aguardar aprovação dos aprovadores do Environment `PRD`

### O que acontece

1. Faz checkout com `GH_PAT`
2. Localiza o merge commit do PR da release branch
3. Executa `git revert -m 1` do merge commit (reverte a release inteira)
4. Faz push do revert na `main`
5. Cria tag no formato `rollback-release-YYYY-MM-DD-YYYYMMDD-HHMMSS`
6. Comenta no PR da release com `🔴 ROLLBACK EXECUTADO`
7. O push na `main` dispara automaticamente o Deploy PRD e restaura PRD

### Pré-requisitos

- Secret `GH_PAT` com Personal Access Token com push em branches protegidas
- Environment `PRD` configurado com aprovadores
- O PR da release branch deve ter sido mergeado na `main`

### Após o rollback

1. Investigar o problema
2. Criar nova release branch (ex: `release/hotfix-2026-05-24`)
3. Squads abrem novos PRs com as correções
4. Passar por todo o fluxo novamente (CI → UAT → GMUD → PRD)

---

## Sequência Completa do Pipeline

### Fluxo de uma squad (individual)

```
 FASE                AÇÃO                              QUEM              WORKFLOW
───────────────────────────────────────────────────────────────────────────────────
 1. Release Branch   Criada a partir da main            Release Manager   —
 2. Desenvolvimento  Push na feature branch              Dev               —
 3. PR               Abre PR para release/*              Dev               —
 4. CI               Validação automática                Automático        ci-validate
 5. Code Review      1ª aprovação                        Reviewer 1        —
 6. Code Review      2ª aprovação                        Reviewer 2        deploy-uat (auto)
 7. UAT              Deploy automático em UAT            Automático        deploy-uat
 8. Homologação      Testa em UAT                        Squad/QA          —
 9. Label            Adiciona "homologado"               QA/Tech Lead      gmud-gate (auto)
10. GMUD             Abre GMUD na ferramenta             Dev/Tech Lead     —
11. GMUD             Aprovação no fórum do CoE           CoE               —
12. Label            Adiciona "GMUD-XXXX"                Release Manager   gmud-gate (auto)
13. Merge            GMUD Gate ✅ → merge na release     Dev/Tech Lead     —
14. Rebase           Notifica outros PRs abertos         Automático        notify-rebase
```

### Fluxo do dia do deploy (Release Manager)

```
 FASE                AÇÃO                              QUEM              WORKFLOW
───────────────────────────────────────────────────────────────────────────────────
 1. PR               Abre PR: release/* → main          Release Manager   —
 2. Merge            Mergeia o PR                        Release Manager   —
 3. Aprovação        Aprova no environment PRD           Aprovador PRD     deploy-prd
 4. Deploy           Validate + Quick Deploy em PRD      Automático        deploy-prd
 5. Tag              Tag com aprovador + data + GMUDs    Automático        deploy-prd
 6. Validação        Valida em produção                  Squads            —
```

### Fluxo com rollback

```
 FASE                AÇÃO                              QUEM              WORKFLOW
───────────────────────────────────────────────────────────────────────────────────
 1. Problema         Identificado bug em PRD             Squad/Monitoração —
 2. Rollback         Executa rollback manual             Release Manager   rollback-prd
 3. Aprovação        Aprova no environment PRD           Aprovador PRD     rollback-prd
 4. Revert           Revert da release inteira na main   Automático        rollback-prd
 5. Deploy           Deploy do revert em PRD             Automático        deploy-prd
 6. Correção         Squads corrigem em nova release     Devs              ci-validate (reinicia)
```

### Exemplo com múltiplas squads

```
                        release/2026-05-23
                               │
  Squad A ──► PR #10 ──────────┤  CI ✅ → UAT ✅ → homologado → GMUD-4821 → merge ✅
                               │
  Squad B ──► PR #11 ──────────┤  CI ✅ → UAT ✅ → homologado → GMUD-4822 → merge ✅
                               │  (rebase após merge do PR #10)
                               │
  Squad C ──► PR #12 ──────────┤  CI ✅ → UAT ✅ → homologado → GMUD-4823 → merge ✅
                               │  (rebase após merge do PR #11)
                               │
                               ▼
            Release Manager: PR release/2026-05-23 → main
                               │
                               ▼
                     Deploy PRD (1 deploy com tudo)
                     Tag: prd-20260523-143000
                       ├── Aprovado por: release-manager
                       ├── GMUDs: GMUD-4821, GMUD-4822, GMUD-4823
                       └── PRs: 3
```

---

## Secrets Necessários

| Secret | Descrição | Usado em |
|--------|-----------|----------|
| `SF_CI_AUTH_URL` | SFDX Auth URL da org CI | ci-validate |
| `SF_UAT_AUTH_URL` | SFDX Auth URL da org UAT | deploy-uat |
| `SF_PRD_AUTH_URL` | SFDX Auth URL da org PRD | deploy-prd |
| `GH_PAT` | Personal Access Token com push em branches protegidas | rollback-prd |
| `GITHUB_TOKEN` | Automático do GitHub (não precisa configurar) | Todos |

Para gerar uma SFDX Auth URL:
```bash
sf org display --verbose --json | jq -r '.result.sfdxAuthUrl'
```

---

## Configurações do Repositório

### Branch Protection Rules

**Branches `release/*`** (Settings > Branches > Add rule > `release/*`):

- ✅ Require a pull request before merging
- ✅ Require approvals: 2
- ✅ Require status checks to pass before merging
  - `Validate in CI Org` (ci-validate)
  - `Validate Homologation & GMUD` (gmud-gate)
- ✅ Require branches to be up to date before merging

**Branch `main`** (Settings > Branches > Add rule > `main`):

- ✅ Require a pull request before merging
- ✅ Restrict who can push (apenas GitHub Actions e Release Manager)

### Environments

Em Settings > Environments:

- **PRD**: Configurar Required reviewers (aprovadores do deploy em produção)

---

## Criando uma Release Branch

O Release Manager cria a release branch a partir da `main`:

```bash
git checkout main
git pull origin main
git checkout -b release/2026-05-23
git push origin release/2026-05-23
```

Após a criação, comunicar as squads para que apontem seus PRs para a nova release branch.

---

## Checklist do Release Manager — Dia do Deploy

1. Verificar que todos os PRs esperados foram mergeados na release branch
2. Verificar que todas as GMUDs estão aprovadas
3. Criar PR: `release/2026-05-23` → `main`
4. Mergear o PR
5. Aprovar o deploy no environment PRD (ou solicitar aprovação)
6. Acompanhar o deploy nos logs do GitHub Actions
7. Validar que a tag foi criada com as informações corretas
8. Comunicar as squads que o deploy foi realizado
9. Deletar a release branch após confirmação
