<h1><img src="assets/icon.svg" width="28" alt="" /> Token Barrage</h1>

*[English version](README.en.md)*

**L'essentiel de ce que fait un agent de code n'est pas du raisonnement. C'est de l'I/O.**

Il ouvre cinq fichiers pour répondre sur un seul. Il écrit le vingt-et-unième test qui ressemble aux vingt précédents. Un volume énorme, presque aucun jugement — et tout est facturé au tarif du modèle frontier.

token-barrage retient ce flux. Le travail de manœuvre part chez un modèle worker bon marché ; le modèle cher ne le voit jamais.

Pas de SaaS, pas de clé API. Ça tourne sur l'abonnement Claude Code que tu as déjà.

![Licence: Apache-2.0](https://img.shields.io/badge/licence-Apache--2.0-0061FF) ![Installation: claude plugin](https://img.shields.io/badge/install-claude%20plugin-0061FF) ![Par L'Accélérateur IA](https://img.shields.io/badge/par-L'Acc%C3%A9l%C3%A9rateur%20IA-0F172A) ![Statut: bêta](https://img.shields.io/badge/statut-b%C3%AAta-F59E0B)

> ### ⚠️ Bêta, publiée pour être testée
>
> Ce dépôt n'est pas un outil abouti, c'est une expérience documentée.
>
> L'économie de contexte est réelle et vérifiée : **87,9 % en moyenne**, 97 à 98 %
> au-dessus du seuil, mesurés en tokens facturés. Mais en usage réel avec un modèle
> frontier, **le plugin n'a pas payé sur la tâche testée** : Opus ne charge pas les
> gros fichiers, il les interroge au `grep`, et le hook n'a alors rien à bloquer.
>
> Tout est écrit, chiffres et limites compris, dans **[TROUVAILLES.md](TROUVAILLES.md)** :
> la méthode de mesure, les quatre bugs trouvés dans le plugin d'origine, et l'A/B
> qui retourne la conclusion.
>
> Si tu le testes, le registre `.barrage/ledger.jsonl` enregistre le coût réel de
> chaque délégation. Les retours sont bienvenus.

---

## Installation

```bash
claude plugin marketplace add naiersaidane/token-barrage
claude plugin install token-barrage@token-barrage
```

Il te faut [`jq`](https://jqlang.org) (`brew install jq`) et le CLI `claude`. Rien d'autre.

---

## Comment ça marche

Trois couches, de la barrière dure à la simple suggestion.

**1. Les hooks — la seule couche qui contraigne vraiment.**
Un hook `PreToolUse` bloque `Read` sur tout fichier de plus de 350 lignes, et bloque `cat`/`head`/`tail`/`less`/`more` sur les mêmes. Les lectures ciblées (`offset`/`limit`), les pipes et les redirections passent sans être touchés.

**2. Les scripts — la délégation elle-même.**
`bulk-read` encadre les fichiers en balises XML et les envoie au worker avec ta question. `code-write` envoie une spec plus un fichier de référence, et écrit le résultat directement sur le disque. Ni l'un ni l'autre corpus n'entre dans le contexte du modèle principal.

**3. Les skills — quand y recourir.**
Deux fichiers `SKILL.md` indiquent à l'agent quand la délégation est le bon geste.

L'ordre compte. Les règles écrites sont ignorées — c'est exactement pour ça que la couche 1 existe. **Une règle est une suggestion. Un blocage est une architecture.**

---

## Mesures

Pas estimées. Mesurées, en tokens réellement facturés.

| Scénario | Lignes | Contexte économisé | Étendue | **Gain net par appel** |
|---|---|---|---|---|
| Fichier unique volumineux | 602 | **98,2 %** | 97,9 – 98,4 | **+$0,0652** |
| Lecture croisée multi-fichiers | 692 | **97,3 %** | 96,9 – 97,7 | **+$0,0683** |
| Source + test | 90 | 68,2 % | 56,4 – 75,6 | **−$0,0024** |
| **Moyenne** | | **87,9 %** | 83,9 – 90,4 | |

Refais-les toi-même :

```bash
bash bench/run.sh
```

### Ce que les chiffres disent

**Les économies sont réelles, et au-dessus du seuil elles dépassent ce qui est annoncé.** Spotify publie 82–94 % pour le plugin équivalent. Sur les mêmes fixtures, au-dessus du seuil, on mesure 97–98 % avec moins d'un point de dispersion.

**Le seuil de 350 lignes est la frontière entre gagner et perdre de l'argent.** Le scénario à 90 lignes est *net négatif* : −$0,0024 par appel. L'overhead du worker mange l'économie. C'est aussi le plus instable — ±10 points d'étendue, contre moins d'un point au-dessus du seuil. Sous le seuil, non seulement tu perds, mais tu ne peux pas prévoir combien.

**Le cache pilote le coût davantage que la taille du corpus.** Le même scénario coûte **$0,0415 à froid et $0,0071 à chaud — 5,9×** — à payload quasi identique. Le premier appel paie l'écriture du cache pour tous les suivants. Le tableau ci-dessus reporte le régime établi.

### Méthode

Les décomptes de tokens viennent d'une **mesure différentielle** : le même appel est passé à vide puis en portant le texte, à drapeaux strictement identiques, et la différence isole le payload. Le contexte total vaut `input + cache_write + cache_read`, une somme indépendante de l'état du cache. On mesure donc des tokens facturés, au lieu de les approximer par une heuristique `chars / 4`.

Le coût du worker est lu dans `bench/ledger.jsonl`, qui enregistre les tokens et les dollars réels de chaque délégation. C'est ce qui permet au tableau de donner un gain **net**, et pas seulement une économie brute.

**Limites, dites clairement :** 3 passes sur 3 scénarios, avec des fixtures TypeScript et non un gros monorepo. Le worker est Claude Haiku 4.5. Les économies côté modèle principal sont valorisées au tarif catalogue de Claude Opus 5 en entrée ($5/MTok). Les résumés étant génératifs, ils varient d'un tirage à l'autre — d'où les étendues.

---

## Ce qui ne se délègue pas

Le plugin est fait pour savoir quand s'effacer.

- **Le débogage** — un modèle bon marché repère les motifs de surface et rate le bug subtil. Il faut le raisonnement du modèle cher, pas un résumé.
- **L'édition** — une édition exige le contenu exact et les bons numéros de ligne. Utilise une lecture ciblée (`offset`/`limit`).
- **L'architecture et le code critique** — le jugement reste au modèle cher.
- **Les petits fichiers** — sous le seuil, déléguer coûte plus que ça ne rapporte. Le chiffre plus haut le prouve.

---

## Configuration

À placer dans le bloc `env` de `.claude/settings.json`.

| Variable | Défaut | Rôle |
|---|---|---|
| `BARRAGE_MIN_LINES` | `350` | Nombre de lignes au-delà duquel la lecture est bloquée et redirigée |
| `BARRAGE_WORKER_MODEL` | `claude-haiku-4-5-20251001` | Le modèle worker |
| `BARRAGE_LEDGER` | `.barrage/ledger.jsonl` | Où le coût de chaque délégation est enregistré |

Le worker tourne avec ses définitions d'outils supprimées et le prompt système de Claude Code remplacé — il n'a besoin d'aucun outil, puisque tout le corpus est dans le message. Ça fait tomber l'overhead fixe de 24 706 tokens à **11 406**, soit **−54 %**. En régime établi ces tokens sont servis par le cache, pour environ **$0,001 par délégation**.

L'empreinte du plugin lui-même est de **~199 tokens ajoutés à chaque session** (deux descriptions de skills ; les hooks tournent dans le harness et ne coûtent aucun contexte modèle). Vérifiable avec `claude plugin details token-barrage@token-barrage`.

---

## Différences avec shunt (Spotify)

C'est un portage de [`shunt`](https://github.com/spotify/portal-ai-plugins/tree/main/plugins/shunt), le plugin publié par Spotify sous Apache-2.0. **L'architecture est la leur.** Les corrections ci-dessous sont sorties du portage et de la mesure.

| | shunt | token-barrage |
|---|---|---|
| Backend | Instance Portal + AiKA (SaaS commercial, essai sur candidature) | Ton abonnement Claude Code existant |
| Payload de passage | `{"decision": "allow"}` — invalide dans l'ancien schéma (`approve\|block`) comme dans l'actuel ; Claude Code le rejette à chaque passage | Sortie en code 0, rien émis — le flux de permissions normal décide |
| Payload de blocage | Champ top-level `decision`, déprécié | `hookSpecificOutput.permissionDecision` |
| `offset:0` / `limit:0` | Contournement documenté | Bloqués |
| `head -n 5 gros.txt` | Le parseur prend `5` pour le chemin, la commande passe | Bloquée |
| Plafond de requête | `ARG_MAX` — 400 Ko macOS, 120 Ko Linux | Aucun, le payload passe par stdin |
| Coût du worker | Non observable (AiKA est une boîte noire) | Enregistré appel par appel dans un registre |

Sur le payload de passage : forcer `"allow"` — si la valeur était valide — **court-circuiterait les permissions de l'utilisateur** sur chaque `Read` et chaque commande Bash sous le seuil. Ne rien émettre et sortir en code 0 est le comportement documenté, et le seul sûr.

Leur propre suite de tests lit la sortie du hook avec `jq -r '.decision'` et la compare à la chaîne qu'elle vient de produire : les 51 tests passent au vert pendant que le plugin part en erreur à chaque passage en conditions réelles.

---

## Crédits

L'architecture, le découpage en trois couches, le seuil de 350 lignes et les scénarios de mesure viennent tous de [portal-ai-plugins](https://github.com/spotify/portal-ai-plugins) de Spotify. Les fixtures de `bench/fixtures/` sont les leurs, reprises sous Apache-2.0 pour que le banc tourne sans cloner leur dépôt — et pour que la comparaison porte sur exactement le même corpus.

Apache-2.0.

---

## Aller plus loin

<p align="center">
  <img src="assets/hero.png" alt="L’Accélérateur IA" width="640">
</p>

Si tu veux apprendre à utiliser Claude Code et en faire un revenu récurrent, jette un œil à **L'Accélérateur IA**.

👉 **[Découvrir L'Accélérateur IA](https://laccelerateuria.com)**
