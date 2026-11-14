#!/usr/bin/env node
/**
 * Vérifie qu'une modification ne touche que des commentaires.
 *
 * Pourquoi ce script existe
 * -------------------------
 * Le code d'iClub est commenté en détail pour qu'un repreneur, ou tout nouveau
 * développeur, le comprenne sans aide (voir docs/collaboration/NORME-COMMENTAIRES.md).
 * Une passe de commentaires porte sur des centaines de fichiers à la fois : il faut
 * pouvoir prouver, fichier par fichier, qu'elle n'a changé aucun caractère de code.
 * Relire le diff à l'œil ne suffit pas à cette échelle. Ce script compare donc chaque
 * fichier à sa version de référence (un commit git), de deux façons.
 *
 * 1. Les jetons. Le fichier est réduit à la suite de ses jetons (mots-clés,
 *    identifiants, littéraux, ponctuation), commentaires et blancs retirés. Si les deux
 *    suites sont identiques, le fichier se comporte exactement comme avant.
 * 2. Les lignes de code. Chaque ligne, une fois ses commentaires effacés et ses blancs
 *    de fin retirés, les lignes vides écartées, doit être identique au caractère près,
 *    indentation comprise. Cette seconde comparaison attrape les retouches de mise en
 *    page sans effet sur le comportement (une espace perdue autour d'un « = » en
 *    JavaScript, une indentation changée), qu'une passe de commentaires ne doit pas
 *    faire non plus. Les outils d'édition en produisent parfois sans qu'on le veuille.
 *
 * Usage
 * -----
 *   node scripts/commentaires-seuls.mjs [--base <référence>] [--ecarts] [--sans-mise-en-page] [chemin ...]
 *
 *   --base <référence>   commit, branche ou étiquette de comparaison (HEAD par défaut).
 *   --ecarts             n'affiche que les fichiers qui posent problème.
 *   --sans-mise-en-page  ne compare que les jetons (le comportement), pas les lignes.
 *   chemin ...           fichiers à vérifier. Sans chemin, le script prend tous les
 *                        fichiers suivis par git qui diffèrent de la référence.
 *
 * Résultat, une ligne par fichier :
 *   IDENTIQUE     jetons et lignes de code identiques ;
 *   MISE EN PAGE  même comportement, mais une ligne de code a changé de forme ;
 *   DIFFÉRENT     les jetons diffèrent : le comportement peut avoir changé ;
 *   NOUVEAU       fichier absent de la référence, rien à comparer ;
 *   IGNORÉ        format non analysé dont le contenu a changé : à relire à la main ;
 *   ERREUR        fichier introuvable ou analyse impossible.
 * Code de sortie : 1 dès qu'un fichier est DIFFÉRENT, MISE EN PAGE, IGNORÉ ou ERREUR ;
 * 0 sinon. Un fichier NOUVEAU ne fait pas échouer la vérification.
 *
 * Méthode, langage par langage
 * ----------------------------
 * - TypeScript et JavaScript (.ts, .tsx, .js, .jsx, .mjs, .cjs) : le fichier est
 *   analysé par le compilateur TypeScript (paquet typescript de node_modules). Les
 *   commentaires, y compris les blocs JSDoc que le compilateur rattache aux
 *   déclarations, sont écartés. En JSX, un commentaire s'écrit {/* ... *\/} : cette
 *   expression vide ne produit rien à l'écran et elle est écartée aussi. Le texte JSX
 *   est ramené à ce que React affiche réellement (blancs de début et de fin de ligne
 *   retirés, lignes vides supprimées), si bien qu'un commentaire glissé au milieu d'une
 *   phrase affichée, qui changerait le rendu, est bien détecté. Sans le compilateur
 *   (dépôt sans node_modules), un fichier JavaScript passe par le lecteur simple
 *   décrit plus bas pour le HTML ; un fichier TypeScript est alors en ERREUR.
 * - SQL : commentaires « -- » et « /* *\/ » (imbriqués, comme dans PostgreSQL) retirés,
 *   chaînes, identifiants entre guillemets et corps de fonctions entre dollars
 *   conservés (les commentaires à l'intérieur des corps sont retirés aussi).
 * - CSS : commentaires « /* *\/ » retirés sans laisser de blanc (en CSS, un
 *   commentaire sépare deux jetons sans valoir une espace), chaînes conservées.
 * - Swift : commentaires « // », « /// » et « /* *\/ » (imbriqués) retirés, chaînes
 *   simples, multilignes et brutes conservées avec leurs interpolations.
 * - Python : comparaison des arbres syntaxiques produits par python3, chaînes de
 *   documentation (docstrings) exclues des deux côtés ; les lignes de code sont lues
 *   après effacement des commentaires « # » et des docstrings.
 * - HTML : commentaires « <!-- --> » retirés, et dans les balises <script> et <style>,
 *   les commentaires du langage concerné.
 * Pour SQL, CSS, Swift et HTML, les jetons sont les mots que séparent les blancs.
 *
 * Limites connues
 * ---------------
 * - Un commentaire ajouté à l'intérieur d'une interpolation Swift \( ... ) n'est pas
 *   retiré : il serait signalé comme un écart (faux positif, sans risque).
 * - Dans le JavaScript des balises <script> d'une page HTML, une expression régulière
 *   qui contient « // » peut être lue comme un début de commentaire ; les deux versions
 *   sont lues de la même façon, seule une modification de la fin de cette ligne précise
 *   échapperait à la comparaison des jetons.
 * - Un commentaire écrit au milieu d'une ligne de code (« a /* x *\/ b ») est accepté
 *   s'il n'a déplacé que les blancs qui l'entourent (voir lignesDeCode). La norme
 *   préfère les commentaires sur leur propre ligne ; une feuille de style ou un type
 *   écrits sur une seule ligne ne laissent parfois pas d'autre place.
 * - Les lignes vides ne comptent pas : en ajouter autour d'un bloc de commentaires est
 *   permis.
 */

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

/** Taille maximale lue depuis git : le plus gros fichier suivi fait quelques centaines de ko. */
const TAMPON_GIT = 256 * 1024 * 1024;

/**
 * @typedef {{ texte: string, ligne: number }} Element
 *   Un jeton ou une ligne de code, avec son numéro de ligne dans le fichier.
 * @typedef {{ debut: number, fin: number, separe: boolean }} Effacement
 *   Une plage de caractères à effacer (indices dans le texte du fichier). « separe »
 *   vrai : la plage est remplacée par des espaces, car le commentaire valait un blanc
 *   entre deux mots ; faux : elle est retirée sans rien laisser (commentaire HTML,
 *   expression JSX vide).
 * @typedef {{ jetons: Element[], lignes: Element[] }} Analyse
 *   Ce que chaque lecteur rend d'un fichier : ses jetons et ses lignes de code.
 */

// ---------------------------------------------------------------------------
// Arguments et accès à git
// ---------------------------------------------------------------------------

/**
 * Lit la ligne de commande.
 * @param {string[]} argv arguments après le nom du script.
 * @returns {{ base: string, ecartsSeulement: boolean, miseEnPage: boolean, aide: boolean, chemins: string[] }}
 */
function lireArguments(argv) {
  const options = { base: "HEAD", ecartsSeulement: false, miseEnPage: true, aide: false, chemins: [] };
  for (let i = 0; i < argv.length; i++) {
    const argument = argv[i];
    if (argument === "--base") options.base = argv[++i];
    else if (argument === "--ecarts") options.ecartsSeulement = true;
    else if (argument === "--sans-mise-en-page") options.miseEnPage = false;
    else if (argument === "--help" || argument === "-h") options.aide = true;
    else options.chemins.push(argument);
  }
  return options;
}

/**
 * Lance une commande git et rend sa sortie texte.
 * @param {string[]} args arguments de git.
 * @returns {string}
 */
function git(args) {
  return execFileSync("git", args, { encoding: "utf8", maxBuffer: TAMPON_GIT, stdio: ["ignore", "pipe", "pipe"] });
}

/**
 * Contenu d'un fichier dans la version de référence, ou null s'il n'y existait pas.
 * @param {string} base référence git (commit, branche).
 * @param {string} cheminDepot chemin relatif à la racine du dépôt, séparateurs « / ».
 * @returns {string | null}
 */
function contenuDeReference(base, cheminDepot) {
  try {
    return git(["show", `${base}:${cheminDepot}`]);
  } catch {
    return null;
  }
}

/**
 * Fichiers suivis qui diffèrent de la référence, copie de travail comprise.
 * Les fichiers supprimés sont écartés : il n'y a plus rien à comparer.
 * @param {string} base référence git.
 * @returns {string[]} chemins relatifs à la racine du dépôt.
 */
function fichiersModifies(base) {
  return git(["diff", "--name-only", "--diff-filter=AMR", base]).split("\n").filter(Boolean);
}

// ---------------------------------------------------------------------------
// Lignes de code
// ---------------------------------------------------------------------------

/** Vrai pour un blanc qui n'est pas un retour à la ligne. */
const estBlanc = (c) => c === " " || c === "\t" || c === "\f" || c === "\v" || c === "\r" || c === " " || c === "﻿";

/**
 * Efface les commentaires d'un texte et rend ses lignes de code non vides.
 *
 * Règle des blancs voisins : un commentaire ajouté dans une ligne de code apporte
 * presque toujours une espace avec lui (« a b » devient « a /* x *\/ b »). Sur chaque
 * ligne, une suite de blancs et de commentaires effacés est donc remplacée :
 * - en début de ligne, par l'indentation qui précède le premier commentaire ;
 * - en fin de ligne, par rien (les blancs de fin ne comptent pas) ;
 * - ailleurs, par le plus long des deux blancs qui l'entourent (celui d'avant le
 *   premier commentaire ou celui d'après le dernier).
 * Une suite de blancs sans commentaire est gardée telle quelle : une espace perdue ou
 * ajoutée dans le code reste visible.
 * Les retours à la ligne ne sont jamais effacés : chaque ligne garde son numéro.
 *
 * @param {string} texte source complète.
 * @param {Effacement[]} effacements plages à effacer (indices en unités UTF-16, ceux
 *   des chaînes JavaScript et du compilateur TypeScript).
 * @returns {Element[]} les lignes de code, blancs de fin retirés, sans les lignes vides.
 */
function lignesDeCode(texte, effacements) {
  const efface = new Uint8Array(texte.length);
  for (const { debut, fin } of effacements) {
    for (let i = debut; i < fin && i < texte.length; i++) if (texte[i] !== "\n") efface[i] = 1;
  }
  const lignes = [];
  let debutLigne = 0;
  for (let numero = 1; debutLigne <= texte.length; numero++) {
    let finLigne = texte.indexOf("\n", debutLigne);
    if (finLigne === -1) finLigne = texte.length;
    let sortie = "";
    let i = debutLigne;
    while (i < finLigne) {
      if (!efface[i] && !estBlanc(texte[i])) {
        sortie += texte[i];
        i++;
        continue;
      }
      // Une suite de blancs et de caractères effacés : jusqu'où va-t-elle ?
      let j = i;
      let premier = -1;
      let dernier = -1;
      while (j < finLigne && (efface[j] || estBlanc(texte[j]))) {
        if (efface[j]) {
          if (premier === -1) premier = j;
          dernier = j;
        }
        j++;
      }
      if (premier === -1) sortie += texte.slice(i, j);
      else if (i === debutLigne) sortie += texte.slice(i, premier);
      else if (j < finLigne) {
        const avant = texte.slice(i, premier);
        const apres = texte.slice(dernier + 1, j);
        sortie += avant.length >= apres.length ? avant : apres;
      }
      i = j;
    }
    sortie = sortie.replace(/\s+$/, "");
    if (sortie.trim() !== "") lignes.push({ texte: sortie, ligne: numero });
    debutLigne = finLigne + 1;
  }
  return lignes;
}

// ---------------------------------------------------------------------------
// TypeScript et JavaScript : analyse par le compilateur
// ---------------------------------------------------------------------------

const exiger = createRequire(import.meta.url);
/** Le compilateur n'est chargé qu'au premier fichier TypeScript ou JavaScript rencontré. */
let compilateur = null;

/**
 * Charge le compilateur TypeScript, une seule fois.
 * @returns {typeof import("typescript")}
 * @throws si le paquet typescript est introuvable.
 */
function chargerTypeScript() {
  if (compilateur) return compilateur;
  try {
    compilateur = exiger("typescript");
  } catch {
    throw new Error("le paquet typescript est introuvable (lancer npm install dans iclub-web)");
  }
  return compilateur;
}

/**
 * Ramène un texte JSX à ce que React affiche, selon la règle du compilateur
 * (fonction fixupWhitespaceAndDecodeEntities de TypeScript) : chaque ligne est
 * débarrassée de ses blancs de début et de fin, les lignes vides disparaissent et les
 * lignes restantes sont jointes par une espace. Les blancs de début de la première
 * ligne et de fin de la dernière sont gardés, car ils touchent une balise.
 * @param {string} texte texte brut entre deux balises ou expressions.
 * @returns {string | undefined} le texte affiché, ou undefined s'il n'affiche rien.
 */
function texteJsxAffiche(texte) {
  let resultat;
  let premierVisible = 0;
  let dernierVisible = -1;
  const ajouterLigne = (ligne) => (resultat === undefined ? ligne : `${resultat} ${ligne}`);
  for (let i = 0; i < texte.length; i++) {
    const c = texte[i];
    if (c === "\n" || c === "\r" || c === " " || c === " ") {
      if (premierVisible !== -1 && dernierVisible !== -1) {
        resultat = ajouterLigne(texte.slice(premierVisible, dernierVisible + 1));
      }
      premierVisible = -1;
    } else if (!/[\t\v\f  ﻿]/.test(c)) {
      dernierVisible = i;
      if (premierVisible === -1) premierVisible = i;
    }
  }
  return premierVisible !== -1 ? ajouterLigne(texte.slice(premierVisible)) : resultat;
}

/**
 * Analyse un fichier TypeScript ou JavaScript : jetons et lignes de code.
 * @param {string} texte contenu du fichier.
 * @param {string} nomFichier sert à choisir la variante (TS, TSX, JS, JSX).
 * @returns {Analyse}
 */
function analyseTypeScript(texte, nomFichier) {
  const extension = path.extname(nomFichier).toLowerCase();
  let ts;
  try {
    ts = chargerTypeScript();
  } catch (erreur) {
    // Sans compilateur, le JavaScript passe par le lecteur simple ; le TypeScript, non.
    if ([".js", ".mjs", ".cjs"].includes(extension)) return analyseParLecteur(lireJavaScriptSimple, texte);
    throw erreur;
  }
  const variante =
    extension === ".tsx" ? ts.ScriptKind.TSX
    : [".ts", ".mts", ".cts"].includes(extension) ? ts.ScriptKind.TS
    : extension === ".jsx" ? ts.ScriptKind.JSX
    : ts.ScriptKind.JS;
  const source = ts.createSourceFile(nomFichier, texte, ts.ScriptTarget.Latest, true, variante);
  /** @type {Element[]} */
  const jetons = [];
  /** Plages [début, fin) des jetons, dans l'ordre du fichier : le reste est blanc ou commentaire. */
  const feuilles = [];
  /** @type {Effacement[]} */
  const effacements = [];
  const pousser = (genre, valeur, position) =>
    jetons.push({ texte: `${genre}:${valeur}`, ligne: source.getLineAndCharacterOfPosition(position).line + 1 });

  const visiter = (noeud) => {
    // Les blocs /** ... */ sont rattachés par le compilateur aux déclarations qu'ils précèdent : ce sont des commentaires.
    if (noeud.kind >= ts.SyntaxKind.FirstJSDocNode && noeud.kind <= ts.SyntaxKind.LastJSDocNode) return;
    // {/* commentaire */} en JSX : une expression vide, qui ne rend rien et s'efface sans laisser de blanc.
    if (noeud.kind === ts.SyntaxKind.JsxExpression && !noeud.expression) {
      effacements.push({ debut: noeud.getStart(source), fin: noeud.getEnd(), separe: false });
      return;
    }
    if (noeud.kind === ts.SyntaxKind.JsxText) {
      const affiche = texteJsxAffiche(noeud.text);
      if (affiche !== undefined) pousser("JsxText", affiche, noeud.getStart(source));
      // Le texte JSX n'a pas de blancs « à côté » : tout son intervalle est du contenu.
      feuilles.push([noeud.pos, noeud.end]);
      return;
    }
    const enfants = noeud.getChildren(source);
    if (enfants.length === 0) {
      if (noeud.kind === ts.SyntaxKind.EndOfFileToken || noeud.kind === ts.SyntaxKind.SyntaxList) return;
      const debut = noeud.getStart(source);
      pousser(noeud.kind, noeud.getText(source), debut);
      feuilles.push([debut, noeud.getEnd()]);
      return;
    }
    for (const enfant of enfants) visiter(enfant);
  };
  visiter(source);

  // Les commentaires sont dans les intervalles entre deux jetons (et avant le premier,
  // après le dernier). Le compilateur les y retrouve : ceux de fin de ligne
  // (getTrailingCommentRanges), puis ceux des lignes suivantes (getLeadingCommentRanges).
  let curseur = 0;
  for (const [debut, fin] of [...feuilles, [texte.length, texte.length]]) {
    if (debut > curseur) {
      const plages = [...(ts.getTrailingCommentRanges(texte, curseur) ?? []), ...(ts.getLeadingCommentRanges(texte, curseur) ?? [])];
      for (const plage of plages) if (plage.end <= debut) effacements.push({ debut: plage.pos, fin: plage.end, separe: true });
    }
    curseur = Math.max(curseur, fin);
  }
  return { jetons, lignes: lignesDeCode(texte, effacements) };
}

// ---------------------------------------------------------------------------
// Lecteurs par caractères : SQL, CSS, Swift, JavaScript simple, HTML
// ---------------------------------------------------------------------------
//
// Chaque lecteur produit des « morceaux » : du code, découpé en mots aux blancs, et
// des littéraux (chaînes) gardés en bloc, chaque littéral formant un jeton à lui seul.
// Il note aussi la position de chaque commentaire rencontré, pour les lignes de code.

/**
 * Accumulateur de jetons et de commentaires, avec le suivi des numéros de ligne.
 */
class Morceaux {
  /**
   * @param {number} [ligneDeDepart] numéro de la première ligne (corps imbriqués).
   */
  constructor(ligneDeDepart = 1) {
    /** @type {Element[]} */
    this.jetons = [];
    /** @type {Effacement[]} plages des commentaires rencontrés, en indices du fichier entier. */
    this.effacements = [];
    this.ligne = ligneDeDepart;
    this.mot = "";
    this.ligneDuMot = ligneDeDepart;
  }

  /** Ajoute un caractère de code ; un blanc termine le mot en cours. */
  code(c) {
    if (/\s/.test(c)) {
      this.finirMot();
      if (c === "\n") this.ligne++;
      return;
    }
    if (this.mot === "") this.ligneDuMot = this.ligne;
    this.mot += c;
  }

  /**
   * Retire un commentaire en gardant le compte de ses retours à la ligne.
   * @param {string} texte le commentaire complet, délimiteurs compris.
   * @param {boolean} separe vrai si le commentaire vaut un blanc et sépare les mots,
   *   comme en SQL, Swift et JavaScript. Faux en HTML et en CSS : « <main><!-- x --><p> »
   *   s'affiche comme « <main><p> », et « .a{}/* x *\/.b{} » se lit comme « .a{}.b{} » ;
   *   le commentaire retiré ne laisse aucun blanc.
   * @param {number} debut position du commentaire dans le fichier entier.
   */
  commentaire(texte, separe, debut) {
    if (separe) this.finirMot();
    this.effacements.push({ debut, fin: debut + texte.length, separe });
    for (const c of texte) if (c === "\n") this.ligne++;
  }

  /** Un littéral (chaîne, délimiteur de corps entre dollars) forme un jeton entier. */
  litteral(texte) {
    this.finirMot();
    this.jetons.push({ texte, ligne: this.ligne });
    for (const c of texte) if (c === "\n") this.ligne++;
  }

  /**
   * Reprend les jetons et les commentaires d'un sous-lecteur (corps de fonction SQL,
   * script ou style HTML). Le mot en cours du sous-lecteur est clos d'abord : sans
   * cela, le dernier mot d'un corps qui ne finit pas par un blanc (« f(1);</script> »)
   * serait perdu.
   */
  absorber(autre) {
    this.finirMot();
    autre.finirMot();
    this.jetons.push(...autre.jetons);
    this.effacements.push(...autre.effacements);
    this.ligne = autre.ligne;
  }

  /** Clôt le mot en cours, s'il y en a un. */
  finirMot() {
    if (this.mot !== "") this.jetons.push({ texte: this.mot, ligne: this.ligneDuMot });
    this.mot = "";
  }

  /** @returns {Element[]} tous les jetons, mot en cours compris. */
  fin() {
    this.finirMot();
    return this.jetons;
  }
}

/**
 * Applique un lecteur par caractères à un fichier entier.
 * @param {(texte: string) => Morceaux} lecteur
 * @param {string} texte contenu du fichier.
 * @returns {Analyse}
 */
function analyseParLecteur(lecteur, texte) {
  const morceaux = lecteur(texte);
  return { jetons: morceaux.fin(), lignes: lignesDeCode(texte, morceaux.effacements) };
}

/**
 * Lit une chaîne délimitée par un même caractère, avec un échappement donné.
 * @param {string} texte source complète.
 * @param {number} debut position du guillemet ouvrant.
 * @param {string} guillemet caractère délimiteur.
 * @param {"double" | "barre"} echappement « double » : le délimiteur doublé vaut un
 *   caractère (SQL) ; « barre » : la barre oblique inverse échappe (CSS, JS).
 * @returns {number} position juste après le guillemet fermant (ou fin du texte).
 */
function finDeChaine(texte, debut, guillemet, echappement) {
  let i = debut + 1;
  while (i < texte.length) {
    const c = texte[i];
    if (echappement === "barre" && c === "\\") {
      i += 2;
      continue;
    }
    if (c === guillemet) {
      if (echappement === "double" && texte[i + 1] === guillemet) {
        i += 2;
        continue;
      }
      return i + 1;
    }
    i++;
  }
  return i;
}

/**
 * Fin d'un commentaire de bloc « /* *\/ », imbriqué ou non.
 * @param {string} texte source complète.
 * @param {number} debut position du « /* » ouvrant.
 * @param {boolean} imbrique vrai si les commentaires s'imbriquent (SQL, Swift).
 * @returns {number} position juste après la fermeture (ou fin du texte).
 */
function finDeBloc(texte, debut, imbrique) {
  let profondeur = 0;
  let i = debut;
  while (i < texte.length) {
    if (texte.startsWith("/*", i)) {
      profondeur++;
      i += 2;
      if (!imbrique && profondeur > 1) profondeur = 1;
      continue;
    }
    if (texte.startsWith("*/", i)) {
      profondeur--;
      i += 2;
      if (profondeur === 0) return i;
      continue;
    }
    i++;
  }
  return i;
}

/**
 * SQL (PostgreSQL) : commentaires retirés, chaînes et corps entre dollars conservés.
 * @param {string} texte source SQL.
 * @param {number} [ligneDeDepart] numéro de la première ligne, pour les corps imbriqués.
 * @param {number} [decalage] position de ce texte dans le fichier entier.
 * @returns {Morceaux}
 */
function lireSql(texte, ligneDeDepart = 1, decalage = 0) {
  const m = new Morceaux(ligneDeDepart);
  let i = 0;
  while (i < texte.length) {
    const c = texte[i];
    if (texte.startsWith("--", i)) {
      const fin = texte.indexOf("\n", i);
      const arret = fin === -1 ? texte.length : fin;
      m.commentaire(texte.slice(i, arret), true, decalage + i);
      i = arret;
      continue;
    }
    if (texte.startsWith("/*", i)) {
      const fin = finDeBloc(texte, i, true);
      m.commentaire(texte.slice(i, fin), true, decalage + i);
      i = fin;
      continue;
    }
    if (c === "'") {
      // Chaîne E'...' : la barre oblique inverse y échappe le guillemet.
      const prefixeE = /[eE]/.test(texte[i - 1] ?? "") && !/[A-Za-z0-9_]/.test(texte[i - 2] ?? "");
      const fin = finDeChaine(texte, i, "'", prefixeE ? "barre" : "double");
      m.litteral(texte.slice(i, fin));
      i = fin;
      continue;
    }
    if (c === '"') {
      const fin = finDeChaine(texte, i, '"', "double");
      m.litteral(texte.slice(i, fin));
      i = fin;
      continue;
    }
    if (c === "$") {
      const etiquette = /^\$([A-Za-z_][A-Za-z0-9_]*)?\$/.exec(texte.slice(i, i + 64));
      // « $1 » (paramètre positionnel) n'est pas une chaîne entre dollars.
      if (etiquette && !/[A-Za-z0-9_]/.test(texte[i - 1] ?? "")) {
        const ouvrante = etiquette[0];
        const debutCorps = i + ouvrante.length;
        const fermeture = texte.indexOf(ouvrante, debutCorps);
        const finCorps = fermeture === -1 ? texte.length : fermeture;
        // Le corps d'une fonction est du code (PL/pgSQL ou SQL) : on le lit de la même façon.
        m.litteral(ouvrante);
        m.absorber(lireSql(texte.slice(debutCorps, finCorps), m.ligne, decalage + debutCorps));
        m.litteral(ouvrante);
        i = fermeture === -1 ? texte.length : fermeture + ouvrante.length;
        continue;
      }
    }
    m.code(c);
    i++;
  }
  return m;
}

/**
 * CSS : commentaires « /* *\/ » retirés, chaînes conservées.
 * @param {string} texte source CSS.
 * @param {number} [ligneDeDepart]
 * @param {number} [decalage] position de ce texte dans le fichier entier.
 * @returns {Morceaux}
 */
function lireCss(texte, ligneDeDepart = 1, decalage = 0) {
  const m = new Morceaux(ligneDeDepart);
  let i = 0;
  while (i < texte.length) {
    const c = texte[i];
    if (texte.startsWith("/*", i)) {
      // En CSS, un commentaire ne vaut pas un blanc : « .a{}/* x */.b{} » se lit comme
      // « .a{}.b{} ». Il est donc retiré sans couper le mot en cours.
      const fin = finDeBloc(texte, i, false);
      m.commentaire(texte.slice(i, fin), false, decalage + i);
      i = fin;
      continue;
    }
    if (c === "'" || c === '"') {
      const fin = finDeChaine(texte, i, c, "barre");
      m.litteral(texte.slice(i, fin));
      i = fin;
      continue;
    }
    m.code(c);
    i++;
  }
  return m;
}

/**
 * Fin d'une chaîne Swift, quelle que soit sa forme : "..." ou """...""", précédée
 * éventuellement de dièses (chaîne brute #"..."#). Les interpolations \( ... ) sont
 * parcourues en tenant compte des parenthèses et des chaînes qu'elles contiennent.
 * @param {string} texte source Swift.
 * @param {number} debut position du premier dièse ou du guillemet ouvrant.
 * @returns {number} position juste après la fin de la chaîne.
 */
function finDeChaineSwift(texte, debut) {
  let i = debut;
  let dieses = 0;
  while (texte[i] === "#") {
    dieses++;
    i++;
  }
  const multiligne = texte.startsWith('"""', i);
  const ouverture = multiligne ? '"""' : '"';
  i += ouverture.length;
  const fermeture = ouverture + "#".repeat(dieses);
  const echappement = "\\" + "#".repeat(dieses);
  while (i < texte.length) {
    if (texte.startsWith(echappement, i)) {
      const apres = i + echappement.length;
      if (texte[apres] === "(") {
        // Interpolation : on cherche la parenthèse fermante correspondante.
        let profondeur = 1;
        let j = apres + 1;
        while (j < texte.length && profondeur > 0) {
          if (texte[j] === '"' || (texte[j] === "#" && /#*"/.test(texte.slice(j, j + 8)))) {
            j = finDeChaineSwift(texte, j);
            continue;
          }
          if (texte[j] === "(") profondeur++;
          else if (texte[j] === ")") profondeur--;
          j++;
        }
        i = j;
        continue;
      }
      i = apres + 1;
      continue;
    }
    if (texte.startsWith(fermeture, i)) return i + fermeture.length;
    if (!multiligne && texte[i] === "\n") return i; // chaîne simple non fermée : on s'arrête à la ligne.
    i++;
  }
  return i;
}

/**
 * Swift : commentaires retirés, chaînes conservées.
 * @param {string} texte source Swift.
 * @returns {Morceaux}
 */
function lireSwift(texte) {
  const m = new Morceaux();
  let i = 0;
  while (i < texte.length) {
    const c = texte[i];
    if (texte.startsWith("//", i)) {
      const fin = texte.indexOf("\n", i);
      const arret = fin === -1 ? texte.length : fin;
      m.commentaire(texte.slice(i, arret), true, i);
      i = arret;
      continue;
    }
    if (texte.startsWith("/*", i)) {
      const fin = finDeBloc(texte, i, true);
      m.commentaire(texte.slice(i, fin), true, i);
      i = fin;
      continue;
    }
    if (c === '"' || (c === "#" && /^#+"/.test(texte.slice(i, i + 8)))) {
      const fin = finDeChaineSwift(texte, i);
      m.litteral(texte.slice(i, fin));
      i = fin;
      continue;
    }
    m.code(c);
    i++;
  }
  return m;
}

/**
 * JavaScript sans compilateur, pour les balises <script> des pages HTML et pour les
 * dépôts sans node_modules : commentaires retirés, chaînes et gabarits conservés,
 * expressions régulières repérées au contexte.
 * @param {string} texte source JavaScript.
 * @param {number} [ligneDeDepart]
 * @param {number} [decalage] position de ce texte dans le fichier entier.
 * @returns {Morceaux}
 */
function lireJavaScriptSimple(texte, ligneDeDepart = 1, decalage = 0) {
  const m = new Morceaux(ligneDeDepart);
  let i = 0;
  /** Dernier caractère de code non blanc : décide si « / » ouvre une expression régulière. */
  let precedent = "";
  while (i < texte.length) {
    const c = texte[i];
    if (texte.startsWith("//", i)) {
      const fin = texte.indexOf("\n", i);
      const arret = fin === -1 ? texte.length : fin;
      m.commentaire(texte.slice(i, arret), true, decalage + i);
      i = arret;
      continue;
    }
    if (texte.startsWith("/*", i)) {
      const fin = finDeBloc(texte, i, false);
      m.commentaire(texte.slice(i, fin), true, decalage + i);
      i = fin;
      continue;
    }
    if (c === "'" || c === '"' || c === "`") {
      // Les gabarits `...${...}...` sont gardés en bloc, interpolations comprises.
      const fin = finDeChaine(texte, i, c, "barre");
      m.litteral(texte.slice(i, fin));
      precedent = c;
      i = fin;
      continue;
    }
    if (c === "/" && (precedent === "" || /[(,=:[!&|?{};+\-*%<>~^]/.test(precedent))) {
      // Expression régulière : jusqu'à la barre fermante, hors classes [...].
      let j = i + 1;
      let dansClasse = false;
      while (j < texte.length && texte[j] !== "\n") {
        if (texte[j] === "\\") {
          j += 2;
          continue;
        }
        if (texte[j] === "[") dansClasse = true;
        else if (texte[j] === "]") dansClasse = false;
        else if (texte[j] === "/" && !dansClasse) break;
        j++;
      }
      j++;
      while (/[a-z]/i.test(texte[j] ?? "")) j++;
      m.litteral(texte.slice(i, j));
      precedent = "/";
      i = j;
      continue;
    }
    if (!/\s/.test(c)) precedent = c;
    m.code(c);
    i++;
  }
  return m;
}

/**
 * HTML : commentaires « <!-- --> » retirés ; le contenu des balises <script> et
 * <style> passe par le lecteur du langage concerné.
 * @param {string} texte source HTML.
 * @returns {Morceaux}
 */
function lireHtml(texte) {
  const m = new Morceaux();
  let i = 0;
  while (i < texte.length) {
    if (texte.startsWith("<!--", i)) {
      const fin = texte.indexOf("-->", i + 4);
      const arret = fin === -1 ? texte.length : fin + 3;
      m.commentaire(texte.slice(i, arret), false, i);
      i = arret;
      continue;
    }
    const balise = /^<(script|style)\b[^>]*>/i.exec(texte.slice(i, i + 2000));
    if (balise) {
      for (const c of balise[0]) m.code(c);
      const debutContenu = i + balise[0].length;
      const fermeture = texte.toLowerCase().indexOf(`</${balise[1].toLowerCase()}`, debutContenu);
      const finContenu = fermeture === -1 ? texte.length : fermeture;
      const contenu = texte.slice(debutContenu, finContenu);
      // Un <script type="application/ld+json"> ne contient pas de commentaires : le lecteur JS le traite sans dommage.
      const lecteur = balise[1].toLowerCase() === "style" ? lireCss : lireJavaScriptSimple;
      m.absorber(lecteur(contenu, m.ligne, debutContenu));
      i = finContenu;
      continue;
    }
    m.code(texte[i]);
    i++;
  }
  return m;
}

// ---------------------------------------------------------------------------
// Python : arbres syntaxiques et lignes de code, par python3
// ---------------------------------------------------------------------------

/**
 * Programme python3 qui imprime, en JSON :
 * - « jetons » : pour chaque instruction de premier niveau, son numéro de ligne et sa
 *   forme canonique (ast.dump), chaînes de documentation retirées ;
 * - « effacements » : les plages des commentaires « # » (repérés par tokenize) et des
 *   docstrings (repérées dans l'arbre), en indices UTF-16 du fichier, pour que les
 *   lignes de code soient calculées par lignesDeCode comme pour les autres langages.
 *   Les colonnes d'ast sont comptées en octets UTF-8, celles de tokenize en
 *   caractères : les deux sont ramenées en unités UTF-16.
 */
const PROGRAMME_PYTHON = `
import ast, io, json, sys, tokenize
source = sys.stdin.read()
lignes = source.split("\\n")
def u16(s):
    return len(s.encode("utf-16-le")) // 2
debuts = [0]
for l in lignes:
    debuts.append(debuts[-1] + u16(l) + 1)
def position(numero, caracteres):
    return debuts[numero - 1] + u16(lignes[numero - 1][:caracteres])
def en_caracteres(numero, octets):
    return len(lignes[numero - 1].encode("utf-8")[:octets].decode("utf-8", "ignore"))
arbre = ast.parse(source)
plages = []
for n in ast.walk(arbre):
    if isinstance(n, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        corps = n.body
        if corps and isinstance(corps[0], ast.Expr) and isinstance(getattr(corps[0], "value", None), ast.Constant) and isinstance(corps[0].value.value, str):
            d = corps[0]
            plages.append([position(d.lineno, en_caracteres(d.lineno, d.col_offset)), position(d.end_lineno, en_caracteres(d.end_lineno, d.end_col_offset))])
            n.body = corps[1:] or [ast.Pass()]
for t in tokenize.generate_tokens(io.StringIO(source).readline):
    if t.type == tokenize.COMMENT:
        plages.append([position(t.start[0], t.start[1]), position(t.end[0], t.end[1])])
print(json.dumps({
    "jetons": [[getattr(i, "lineno", 0), ast.dump(i)] for i in arbre.body],
    "effacements": plages,
}))
`;

/**
 * Analyse un fichier Python.
 * @param {string} texte source Python.
 * @returns {Analyse}
 */
function analysePython(texte) {
  const sortie = execFileSync("python3", ["-I", "-c", PROGRAMME_PYTHON], { input: texte, encoding: "utf8", maxBuffer: TAMPON_GIT });
  const { jetons, effacements } = JSON.parse(sortie);
  return {
    jetons: jetons.map(([ligne, forme]) => ({ texte: forme, ligne })),
    lignes: lignesDeCode(texte, effacements.map(([debut, fin]) => ({ debut, fin, separe: true }))),
  };
}

// ---------------------------------------------------------------------------
// Aiguillage et comparaison
// ---------------------------------------------------------------------------

/** Extensions prises en charge et analyse associée. */
const ANALYSES = {
  ".ts": analyseTypeScript,
  ".tsx": analyseTypeScript,
  ".mts": analyseTypeScript,
  ".cts": analyseTypeScript,
  ".js": analyseTypeScript,
  ".jsx": analyseTypeScript,
  ".mjs": analyseTypeScript,
  ".cjs": analyseTypeScript,
  ".sql": (texte) => analyseParLecteur(lireSql, texte),
  ".css": (texte) => analyseParLecteur(lireCss, texte),
  ".swift": (texte) => analyseParLecteur(lireSwift, texte),
  ".py": analysePython,
  ".html": (texte) => analyseParLecteur(lireHtml, texte),
  ".htm": (texte) => analyseParLecteur(lireHtml, texte),
};

/**
 * Compare deux suites (jetons ou lignes de code).
 * @param {Element[]} avant
 * @param {Element[]} apres
 * @returns {null | { indice: number, avant?: Element, apres?: Element }} null si elles
 *   sont identiques, sinon le premier écart.
 */
function premierEcart(avant, apres) {
  const longueur = Math.max(avant.length, apres.length);
  for (let i = 0; i < longueur; i++) {
    if (avant[i]?.texte !== apres[i]?.texte) return { indice: i, avant: avant[i], apres: apres[i] };
  }
  return null;
}

/** Quelques jetons autour d'un écart, pour le message d'erreur. */
function contexte(jetons, indice) {
  return jetons
    .slice(Math.max(0, indice - 3), indice + 4)
    .map((j) => j.texte.replace(/^\d+:/, "").replace(/\s+/g, " ").slice(0, 60))
    .join("  ");
}

/** Une ligne de code entre guillemets, blancs visibles, pour le message d'erreur. */
function montrer(element) {
  return element ? `ligne ${element.ligne} ${JSON.stringify(element.texte.slice(0, 140))}` : "(aucune ligne)";
}

function principal() {
  const options = lireArguments(process.argv.slice(2));
  if (options.aide) {
    console.log("node scripts/commentaires-seuls.mjs [--base <référence>] [--ecarts] [--sans-mise-en-page] [chemin ...]");
    return 0;
  }
  const racine = git(["rev-parse", "--show-toplevel"]).trim();
  const chemins = options.chemins.length
    ? options.chemins.map((c) => path.relative(racine, path.resolve(c)).split(path.sep).join("/"))
    : fichiersModifies(options.base);

  const bilan = { identiques: 0, miseEnPage: 0, differents: 0, nouveaux: 0, ignores: 0, erreurs: 0 };
  for (const chemin of chemins) {
    const analyse = ANALYSES[path.extname(chemin).toLowerCase()];
    const absolu = path.join(racine, chemin);
    if (!existsSync(absolu)) {
      console.log(`ERREUR        ${chemin} : fichier introuvable`);
      bilan.erreurs++;
      continue;
    }
    const actuel = readFileSync(absolu, "utf8");
    const ancien = contenuDeReference(options.base, chemin);
    if (ancien === null) {
      if (!options.ecartsSeulement) console.log(`NOUVEAU       ${chemin} (absent de ${options.base})`);
      bilan.nouveaux++;
      continue;
    }
    if (!analyse) {
      // Format inconnu (JSON, Markdown...) : seule une égalité stricte est acceptée.
      if (ancien === actuel) {
        bilan.identiques++;
        if (!options.ecartsSeulement) console.log(`IDENTIQUE     ${chemin}`);
      } else {
        bilan.ignores++;
        console.log(`IGNORÉ        ${chemin} : format non analysé, contenu modifié (à relire à la main)`);
      }
      continue;
    }
    try {
      const avant = analyse(ancien, chemin);
      const apres = analyse(actuel, chemin);
      const ecart = premierEcart(avant.jetons, apres.jetons);
      if (ecart) {
        bilan.differents++;
        const ligneAvant = ecart.avant ? `ligne ${ecart.avant.ligne}` : "fin de fichier";
        const ligneApres = ecart.apres ? `ligne ${ecart.apres.ligne}` : "fin de fichier";
        console.log(`DIFFÉRENT     ${chemin} : premier écart en ${ligneAvant} (référence), ${ligneApres} (actuel)`);
        console.log(`              référence : ${contexte(avant.jetons, ecart.indice)}`);
        console.log(`              actuel    : ${contexte(apres.jetons, ecart.indice)}`);
        continue;
      }
      const ecartDeLigne = options.miseEnPage ? premierEcart(avant.lignes, apres.lignes) : null;
      if (ecartDeLigne) {
        bilan.miseEnPage++;
        console.log(`MISE EN PAGE  ${chemin} : une ligne de code a changé de forme (comportement inchangé)`);
        console.log(`              référence : ${montrer(ecartDeLigne.avant)}`);
        console.log(`              actuel    : ${montrer(ecartDeLigne.apres)}`);
        continue;
      }
      bilan.identiques++;
      if (!options.ecartsSeulement) console.log(`IDENTIQUE     ${chemin}`);
    } catch (erreur) {
      bilan.erreurs++;
      console.log(`ERREUR        ${chemin} : ${erreur instanceof Error ? erreur.message : String(erreur)}`);
    }
  }
  console.log(
    `\n${bilan.identiques} identique(s), ${bilan.miseEnPage} mise(s) en page, ${bilan.differents} différent(s), ` +
      `${bilan.nouveaux} nouveau(x), ${bilan.ignores} non analysé(s), ${bilan.erreurs} erreur(s), référence ${options.base}.`,
  );
  return bilan.differents + bilan.miseEnPage + bilan.erreurs + bilan.ignores > 0 ? 1 : 0;
}

process.exitCode = principal();
