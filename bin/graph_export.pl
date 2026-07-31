#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP qw(encode_json);

use FusekiClient qw(sparql_select);

sub load_dotenv {
    my ($file) = @_;
    return unless -f $file;
    open my $fh, '<', $file or return;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/ || $line !~ /=/;
        my ($key, $value) = split /=/, $line, 2;
        $ENV{$key} = $value unless exists $ENV{$key};
    }
    close $fh;
}
load_dotenv("$FindBin::Bin/../.env");

my $FUSEKI_BASE = 'http://localhost:3030';
my $DATASET     = 'bestand';
my $ADMIN_USER  = 'admin';
my $ADMIN_PASS  = $ENV{FUSEKI_ADMIN_PASSWORD} // die "Bitte FUSEKI_ADMIN_PASSWORD setzen\n";
my $LIMIT       = 5000;

my $DC_TITLE   = 'http://purl.org/dc/elements/1.1/title';
my $FOAF_NAME  = 'http://xmlns.com/foaf/0.1/name';
my $SKOS_LABEL = 'http://www.w3.org/2004/02/skos/core#prefLabel';
my %LABEL_PREDICATES = map { $_ => 1 } ($DC_TITLE, $FOAF_NAME, $SKOS_LABEL);

my $query = "SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT $LIMIT";
my $result = sparql_select(
    base_url => $FUSEKI_BASE, name => $DATASET, query => $query,
    user => $ADMIN_USER, pass => $ADMIN_PASS,
);
my @bindings = @{ $result->{results}{bindings} };
print "Abgefragt: " . scalar(@bindings) . " Triples\n";

sub short_label {
    my ($value) = @_;
    (my $label = $value) =~ s{.*[/#]}{};
    return $label;
}

sub classify_node {
    my ($value) = @_;
    return 'author'  if $value =~ m{/author/};
    return 'subject' if $value =~ m{/subject/};
    return 'book'    if $value =~ m{/record/};
    return 'resource';
}

my %entity_label;
my %entities;
my %adjacency;

for my $row (@bindings) {
    my ($s, $p, $o) = ($row->{s}, $row->{p}, $row->{o});
    my $s_id = $s->{value};
    $entities{$s_id} = 1;

    if ($o->{type} eq 'literal') {
        if ($LABEL_PREDICATES{ $p->{value} }) {
            $entity_label{$s_id} = $o->{value};
        }
        next;
    }

    my $o_id = $o->{value};
    $entities{$o_id} = 1;
    my $p_label = short_label($p->{value});

    push @{ $adjacency{$s_id} }, { to => $o_id, label => $p_label };
    push @{ $adjacency{$o_id} }, { to => $s_id, label => $p_label };
}

my @entity_list;
for my $id (keys %entities) {
    push @entity_list, {
        id    => $id,
        label => $entity_label{$id} // short_label($id),
        type  => classify_node($id),
    };
}
print "Entitaeten: " . scalar(@entity_list) . "\n";

my $entities_json  = encode_json(\@entity_list);
my $adjacency_json = encode_json(\%adjacency);

my $output_path = "$FindBin::Bin/../output/explorer.html";

my $html = <<'HTML';
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Bestand Explorer</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: -apple-system, "Segoe UI", sans-serif; margin: 0; background: #ffffff; color: #1a1a1a; }

  #searchbar {
    display: flex; flex-direction: column; align-items: center;
    padding: 20px 16px 10px; border-bottom: 1px solid #e5e5e5;
  }
  #searchbar h1 { font-size: 18px; font-weight: 500; margin: 0 0 12px; color: #333; }
  #search-input {
    width: 100%; max-width: 520px; padding: 10px 16px; font-size: 14px;
    border: 1px solid #ccc; border-radius: 999px; outline: none;
  }
  #search-input:focus { border-color: #3d5a80; }

  #suggestions {
    width: 100%; max-width: 520px; margin-top: 6px;
    border: 1px solid #e5e5e5; border-radius: 10px; overflow: hidden;
    display: none; background: white; box-shadow: 0 4px 12px rgba(0,0,0,0.08);
  }
  #suggestions.visible { display: block; }
  .suggestion { display: flex; align-items: center; gap: 8px; padding: 9px 14px; cursor: pointer; font-size: 13px; }
  .suggestion:hover { background: #f5f5f5; }
  .badge { display: inline-block; width: 9px; height: 9px; border-radius: 50%; flex-shrink: 0; }
  .badge-book { background: #06a77d; }
  .badge-author { background: #d64550; }
  .badge-subject { background: #3d5a80; }
  .badge-resource { background: #999999; }

  #topbar {
    display: flex; align-items: center; justify-content: space-between; padding: 8px 20px;
    font-size: 12px; color: #777; min-height: 18px;
  }
  #reset-btn {
    border: 1px solid #ccc; background: white; border-radius: 6px;
    padding: 4px 10px; cursor: pointer; font-size: 12px; color: #333;
  }
  #reset-btn:hover { background: #f5f5f5; }

  #empty-state { text-align: center; color: #999; font-size: 14px; padding: 80px 20px; }

  svg { width: 100vw; height: calc(100vh - 120px); display: block; }
  .node-book     { fill: #06a77d; stroke: #333; stroke-width: 0.5; cursor: grab; }
  .node-author   { fill: #d64550; stroke: #333; stroke-width: 0.5; cursor: grab; }
  .node-subject  { fill: #3d5a80; stroke: #333; stroke-width: 0.5; cursor: grab; }
  .node-resource { fill: #999999; stroke: #333; stroke-width: 0.5; cursor: grab; }
  .expandable    { stroke: #d64550; stroke-width: 2.5; }
  .node-label    { font-size: 11px; fill: #222; text-anchor: middle; pointer-events: none; }
  .edge-line     { stroke: #d5d5d5; stroke-width: 1.2; }
</style>
</head>
<body>

<div id="searchbar">
  <h1>Bestand Explorer</h1>
  <input id="search-input" type="text" placeholder="Suche nach Werk, Person oder Schlagwort ..." autocomplete="off">
  <div id="suggestions"></div>
</div>

<div id="topbar">
  <span id="stats"></span>
  <button id="reset-btn">Zuruecksetzen</button>
</div>

<div id="empty-state">Suche oben nach einem Werk, einer Person oder einem Schlagwort, um den Graphen zu starten.</div>
<svg id="graph" viewBox="0 0 1400 900" style="display:none"></svg>

<script>
const allEntities = __ENTITIES_JSON__;
const adjacency = __ADJACENCY_JSON__;

const entityMap = {};
allEntities.forEach(e => entityMap[e.id] = e);

const W = 1400, H = 900;
let revealed = new Set();
let visibleEdgeKeys = new Set();
let visibleEdges = [];

const searchInput = document.getElementById('search-input');
const suggestionsBox = document.getElementById('suggestions');
const svg = document.getElementById('graph');
const emptyState = document.getElementById('empty-state');
const resetBtn = document.getElementById('reset-btn');
const statsEl = document.getElementById('stats');

const SVG_NS = 'http://www.w3.org/2000/svg';
function svgEl(tag, attrs) {
    const el = document.createElementNS(SVG_NS, tag);
    for (const k in attrs) el.setAttribute(k, attrs[k]);
    return el;
}

const badgeClass = { book: 'badge-book', author: 'badge-author', subject: 'badge-subject', resource: 'badge-resource' };
const nodeClass  = { book: 'node-book', author: 'node-author', subject: 'node-subject', resource: 'node-resource' };
const typeNameDe = { book: 'Werk', author: 'Person', subject: 'Schlagwort', resource: 'Sonstiges' };

searchInput.addEventListener('input', () => {
    const q = searchInput.value.trim().toLowerCase();
    if (q.length < 2) {
        suggestionsBox.classList.remove('visible');
        suggestionsBox.innerHTML = '';
        return;
    }
    const matches = allEntities.filter(e => e.label.toLowerCase().includes(q)).slice(0, 8);
    suggestionsBox.innerHTML = '';
    matches.forEach(e => {
        const row = document.createElement('div');
        row.className = 'suggestion';
        const badge = document.createElement('span');
        badge.className = 'badge ' + (badgeClass[e.type] || 'badge-resource');
        const text = document.createElement('span');
        text.textContent = e.label + '  ·  ' + (typeNameDe[e.type] || e.type);
        row.appendChild(badge);
        row.appendChild(text);
        row.addEventListener('click', () => {
            suggestionsBox.classList.remove('visible');
            searchInput.value = e.label;
            startGraph(e.id);
        });
        suggestionsBox.appendChild(row);
    });
    suggestionsBox.classList.toggle('visible', matches.length > 0);
});

document.addEventListener('click', evt => {
    if (!suggestionsBox.contains(evt.target) && evt.target !== searchInput) {
        suggestionsBox.classList.remove('visible');
    }
});

resetBtn.addEventListener('click', () => {
    revealed = new Set();
    rebuildScene();
    emptyState.style.display = 'block';
    svg.style.display = 'none';
    searchInput.value = '';
});

function neighborsOf(id) {
    return adjacency[id] || [];
}

function startGraph(id) {
    revealed = new Set();
    const entity = entityMap[id];
    entity.x = W/2; entity.y = H/2; entity.vx = 0; entity.vy = 0;
    revealed.add(id);

    neighborsOf(id).forEach(edge => {
        const nb = entityMap[edge.to];
        if (!nb) return;
        revealed.add(edge.to);
        if (nb.x === undefined) {
            const angle = Math.random() * 2 * Math.PI;
            nb.x = W/2 + Math.cos(angle) * 180;
            nb.y = H/2 + Math.sin(angle) * 180;
            nb.vx = 0; nb.vy = 0;
        }
    });

    emptyState.style.display = 'none';
    svg.style.display = 'block';
    rebuildScene();
}

function expand(id) {
    const parent = entityMap[id];
    neighborsOf(id).forEach(edge => {
        const nb = entityMap[edge.to];
        if (!nb) return;
        if (!revealed.has(edge.to)) {
            const angle = Math.random() * 2 * Math.PI;
            nb.x = parent.x + Math.cos(angle) * 120;
            nb.y = parent.y + Math.sin(angle) * 120;
            nb.vx = 0; nb.vy = 0;
        }
        revealed.add(edge.to);
    });
    rebuildScene();
}

// --- SVG-Elemente fuer aktuell sichtbare Knoten/Kanten verwalten ---
let nodeShapeMap = {};   // id -> { shape, label }
let edgeLineMap = {};    // "from|to" -> line

function rebuildScene() {
    // Sichtbare Kanten neu berechnen
    visibleEdges = [];
    visibleEdgeKeys = new Set();
    revealed.forEach(id => {
        neighborsOf(id).forEach(edge => {
            if (!revealed.has(edge.to)) return;
            const key = [id, edge.to].sort().join('|');
            if (visibleEdgeKeys.has(key)) return;
            visibleEdgeKeys.add(key);
            visibleEdges.push({ from: id, to: edge.to });
        });
    });

    // Alte Elemente entfernen, die nicht mehr gebraucht werden
    Object.keys(nodeShapeMap).forEach(id => {
        if (!revealed.has(id)) {
            nodeShapeMap[id].shape.remove();
            nodeShapeMap[id].label.remove();
            delete nodeShapeMap[id];
        }
    });
    Object.keys(edgeLineMap).forEach(key => {
        if (!visibleEdgeKeys.has(key)) {
            edgeLineMap[key].remove();
            delete edgeLineMap[key];
        }
    });

    // Neue Kanten-Linien anlegen (erst, damit sie unter den Knoten liegen)
    visibleEdges.forEach(e => {
        const key = [e.from, e.to].sort().join('|');
        if (edgeLineMap[key]) return;
        const line = svgEl('line', { class: 'edge-line' });
        svg.appendChild(line);
        edgeLineMap[key] = line;
    });

    // Neue Knoten anlegen
    revealed.forEach(id => {
        if (nodeShapeMap[id]) return;
        const entity = entityMap[id];
        const shape = svgEl('circle', { r: 16 });
        shape.addEventListener('mousedown', evt => startDrag(evt, entity));
        shape.addEventListener('click', () => expand(id));
        svg.appendChild(shape);

        const label = svgEl('text', { class: 'node-label' });
        label.textContent = entity.label;
        svg.appendChild(label);

        nodeShapeMap[id] = { shape, label };
    });

    updateNodeStyles();
    statsEl.textContent = 'Sichtbar: ' + revealed.size + ' Knoten, ' + visibleEdges.length + ' Kanten (von insgesamt ' + allEntities.length + ' Entitaeten)';
}

function updateNodeStyles() {
    revealed.forEach(id => {
        const entity = entityMap[id];
        const hiddenCount = neighborsOf(id).filter(e => !revealed.has(e.to)).length;
        const cls = (nodeClass[entity.type] || 'node-resource') + (hiddenCount > 0 ? ' expandable' : '');
        nodeShapeMap[id].shape.setAttribute('class', cls);
    });
}

// --- Physik-Simulation ---
const REPULSION = 9000, SPRING_LENGTH = 130, SPRING_STRENGTH = 0.02, DAMPING = 0.85, CENTER_PULL = 0.0015;

function simulationStep() {
    const nodes = [...revealed].map(id => entityMap[id]);
    for (let i = 0; i < nodes.length; i++) {
        for (let j = i + 1; j < nodes.length; j++) {
            const a = nodes[i], b = nodes[j];
            let dx = a.x - b.x, dy = a.y - b.y;
            let distSq = dx*dx + dy*dy || 0.01;
            let dist = Math.sqrt(distSq);
            let force = REPULSION / distSq;
            let fx = (dx / dist) * force, fy = (dy / dist) * force;
            a.vx += fx; a.vy += fy;
            b.vx -= fx; b.vy -= fy;
        }
    }

    visibleEdges.forEach(e => {
        const a = entityMap[e.from], b = entityMap[e.to];
        let dx = b.x - a.x, dy = b.y - a.y;
        let dist = Math.sqrt(dx*dx + dy*dy) || 0.01;
        let displacement = dist - SPRING_LENGTH;
        let force = displacement * SPRING_STRENGTH;
        let fx = (dx / dist) * force, fy = (dy / dist) * force;
        a.vx += fx; a.vy += fy;
        b.vx -= fx; b.vy -= fy;
    });

    nodes.forEach(n => {
        if (n.dragging) return;
        n.vx += (W/2 - n.x) * CENTER_PULL;
        n.vy += (H/2 - n.y) * CENTER_PULL;
        n.vx *= DAMPING; n.vy *= DAMPING;
        n.x += n.vx; n.y += n.vy;
    });
}

function draw() {
    visibleEdges.forEach(e => {
        const key = [e.from, e.to].sort().join('|');
        const line = edgeLineMap[key];
        if (!line) return;
        const a = entityMap[e.from], b = entityMap[e.to];
        line.setAttribute('x1', a.x); line.setAttribute('y1', a.y);
        line.setAttribute('x2', b.x); line.setAttribute('y2', b.y);
    });
    revealed.forEach(id => {
        const entity = entityMap[id];
        const { shape, label } = nodeShapeMap[id];
        shape.setAttribute('cx', entity.x);
        shape.setAttribute('cy', entity.y);
        label.setAttribute('x', entity.x);
        label.setAttribute('y', entity.y + 30);
    });
}

function animate() {
    if (revealed.size > 0) { simulationStep(); draw(); }
    requestAnimationFrame(animate);
}

// --- Dragging ---
let dragNode = null, dragOffset = { x: 0, y: 0 };

function startDrag(evt, entity) {
    dragNode = entity;
    entity.dragging = true;
    const pt = toSvgCoords(evt);
    dragOffset.x = pt.x - entity.x;
    dragOffset.y = pt.y - entity.y;
    evt.stopPropagation();
}

function toSvgCoords(evt) {
    const rect = svg.getBoundingClientRect();
    return {
        x: (evt.clientX - rect.left) * (W / rect.width),
        y: (evt.clientY - rect.top) * (H / rect.height)
    };
}

document.addEventListener('mousemove', evt => {
    if (!dragNode) return;
    const pt = toSvgCoords(evt);
    dragNode.x = pt.x - dragOffset.x;
    dragNode.y = pt.y - dragOffset.y;
    dragNode.vx = 0; dragNode.vy = 0;
});

document.addEventListener('mouseup', () => {
    if (dragNode) dragNode.dragging = false;
    dragNode = null;
});

animate();
</script>
</body>
</html>
HTML

$html =~ s/__ENTITIES_JSON__/$entities_json/;
$html =~ s/__ADJACENCY_JSON__/$adjacency_json/;

open my $out, '>:encoding(UTF-8)', $output_path or die "Kann $output_path nicht schreiben: $!\n";
print $out $html;
close $out;

print "Explorer gespeichert: $output_path\n";