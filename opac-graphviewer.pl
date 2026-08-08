#!/usr/bin/perl
use strict;
use warnings;
use CGI;
use JSON::PP qw(encode_json);

# Passe diesen Pfad an, wo dein FusekiClient.pm liegt (dein Uni-Projekt-Repo)
use lib "/home/patrykg/Documents/github/xml2rdf_koha/lib";
use FusekiClient qw(sparql_select);

my $cgi = CGI->new;
print $cgi->header('text/html; charset=UTF-8');

my $biblionumber = $cgi->param('biblionumber') // '';
$biblionumber =~ s/\D//g;   # nur Ziffern zulassen, Sicherheitsmassnahme

unless ($biblionumber) {
    print "<p>Keine Biblionummer angegeben.</p>";
    exit;
}

# --- Konfiguration (idealerweise aus einer Config-Datei/Env statt hartcodiert) ---
my $FUSEKI_BASE = 'http://localhost:3030';
my $DATASET     = 'bestand';
my $ADMIN_USER  = 'admin';
my $ADMIN_PASS  = $ENV{FUSEKI_ADMIN_PASSWORD} || 'admin';

my $DC_TITLE   = 'http://purl.org/dc/elements/1.1/title';
my $FOAF_NAME  = 'http://xmlns.com/foaf/0.1/name';
my $SKOS_LABEL = 'http://www.w3.org/2004/02/skos/core#prefLabel';
my %LABEL_PREDICATES = map { $_ => 1 } ($DC_TITLE, $FOAF_NAME, $SKOS_LABEL);

my $start_id = "http://example.org/record/$biblionumber";

# --- Alle Triples abfragen (fuer ein groesseres Projekt spaeter: nur Umgebung des Start-Knotens abfragen) ---
my $result = sparql_select(
    base_url => $FUSEKI_BASE, name => $DATASET,
    query => "SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 5000",
    user => $ADMIN_USER, pass => $ADMIN_PASS,
);
my @bindings = @{ $result->{results}{bindings} };

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

my (%entity_label, %entities, %adjacency);
for my $row (@bindings) {
    my ($s, $p, $o) = ($row->{s}, $row->{p}, $row->{o});
    my $s_id = $s->{value};
    $entities{$s_id} = 1;

    if ($o->{type} eq 'literal') {
        $entity_label{$s_id} = $o->{value} if $LABEL_PREDICATES{ $p->{value} };
        next;
    }
    my $o_id = $o->{value};
    $entities{$o_id} = 1;
    my $p_label = short_label($p->{value});
    push @{ $adjacency{$s_id} }, { to => $o_id, label => $p_label };
    push @{ $adjacency{$o_id} }, { to => $s_id, label => $p_label };
}

# Falls dieser Datensatz gar nicht in Fuseki existiert
unless ($entities{$start_id}) {
    print "<p>Kein Linked-Data-Eintrag fuer Biblionummer $biblionumber gefunden.</p>";
    exit;
}

my @entity_list;
for my $id (keys %entities) {
    push @entity_list, {
        id => $id, label => $entity_label{$id} // short_label($id), type => classify_node($id),
    };
}

my $entities_json  = encode_json(\@entity_list);
my $adjacency_json = encode_json(\%adjacency);
my $start_id_json  = encode_json($start_id);

my $html = <<'HTML';
<style>
  * { box-sizing: border-box; }
  #graphview-root { font-family: -apple-system, "Segoe UI", sans-serif; }
  #gv-topbar { display: flex; justify-content: space-between; padding: 6px 4px; font-size: 12px; color: #777; }
  #gv-reset { border: 1px solid #ccc; background: white; border-radius: 6px; padding: 3px 9px; cursor: pointer; font-size: 12px; }
  #gv-reset:hover { background: #f5f5f5; }
  #gv-svg { width: 100%; height: 650px; display: block; background: #fafafa; border-radius: 8px; }
  .node-book     { fill: #06a77d; stroke: #333; stroke-width: 0.5; cursor: grab; }
  .node-author   { fill: #d64550; stroke: #333; stroke-width: 0.5; cursor: grab; }
  .node-subject  { fill: #3d5a80; stroke: #333; stroke-width: 0.5; cursor: grab; }
  .node-resource { fill: #999999; stroke: #333; stroke-width: 0.5; cursor: grab; }
  .expandable    { stroke: #d64550; stroke-width: 2.5; }
  .node-label    { font-size: 11px; fill: #222; text-anchor: middle; pointer-events: none; }
  .edge-line     { stroke: #d5d5d5; stroke-width: 1.2; }
</style>

<div id="graphview-root">
  <div id="gv-topbar"><span id="gv-stats"></span><button id="gv-reset">Zuruecksetzen</button></div>
  <svg id="gv-svg" viewBox="0 0 1200 700"></svg>
</div>

<script>
(function() {
  const allEntities = __ENTITIES_JSON__;
  const adjacency = __ADJACENCY_JSON__;
  const startId = __START_ID_JSON__;

  const entityMap = {};
  allEntities.forEach(e => entityMap[e.id] = e);

  const W = 1200, H = 700;
  let revealed = new Set();
  let visibleEdges = [];
  let visibleEdgeKeys = new Set();

  const svg = document.getElementById('gv-svg');
  const statsEl = document.getElementById('gv-stats');
  const resetBtn = document.getElementById('gv-reset');

  const SVG_NS = 'http://www.w3.org/2000/svg';
  function svgEl(tag, attrs) {
    const el = document.createElementNS(SVG_NS, tag);
    for (const k in attrs) el.setAttribute(k, attrs[k]);
    return el;
  }

  const nodeClass = { book: 'node-book', author: 'node-author', subject: 'node-subject', resource: 'node-resource' };

  function neighborsOf(id) { return adjacency[id] || []; }

  function startGraph(id) {
    revealed = new Set();
    const entity = entityMap[id];
    if (!entity) return;
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

  let nodeShapeMap = {}, edgeLineMap = {};

  function rebuildScene() {
    visibleEdges = []; visibleEdgeKeys = new Set();
    revealed.forEach(id => {
      neighborsOf(id).forEach(edge => {
        if (!revealed.has(edge.to)) return;
        const key = [id, edge.to].sort().join('|');
        if (visibleEdgeKeys.has(key)) return;
        visibleEdgeKeys.add(key);
        visibleEdges.push({ from: id, to: edge.to });
      });
    });

    Object.keys(nodeShapeMap).forEach(id => {
      if (!revealed.has(id)) { nodeShapeMap[id].shape.remove(); nodeShapeMap[id].label.remove(); delete nodeShapeMap[id]; }
    });
    Object.keys(edgeLineMap).forEach(key => {
      if (!visibleEdgeKeys.has(key)) { edgeLineMap[key].remove(); delete edgeLineMap[key]; }
    });

    visibleEdges.forEach(e => {
      const key = [e.from, e.to].sort().join('|');
      if (edgeLineMap[key]) return;
      const line = svgEl('line', { class: 'edge-line' });
      svg.appendChild(line);
      edgeLineMap[key] = line;
    });

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
    statsEl.textContent = 'Sichtbar: ' + revealed.size + ' Knoten, ' + visibleEdges.length + ' Kanten';
  }

  function updateNodeStyles() {
    revealed.forEach(id => {
      const entity = entityMap[id];
      const hiddenCount = neighborsOf(id).filter(e => !revealed.has(e.to)).length;
      const cls = (nodeClass[entity.type] || 'node-resource') + (hiddenCount > 0 ? ' expandable' : '');
      nodeShapeMap[id].shape.setAttribute('class', cls);
    });
  }

  const REPULSION = 9000, SPRING_LENGTH = 130, SPRING_STRENGTH = 0.02, DAMPING = 0.85, CENTER_PULL = 0.0015;

  function simulationStep() {
    const nodes = [...revealed].map(id => entityMap[id]);
    for (let i = 0; i < nodes.length; i++) {
      for (let j = i + 1; j < nodes.length; j++) {
        const a = nodes[i], b = nodes[j];
        let dx = a.x - b.x, dy = a.y - b.y;
        let distSq = dx*dx + dy*dy || 0.01, dist = Math.sqrt(distSq);
        let force = REPULSION / distSq;
        let fx = (dx/dist)*force, fy = (dy/dist)*force;
        a.vx += fx; a.vy += fy; b.vx -= fx; b.vy -= fy;
      }
    }
    visibleEdges.forEach(e => {
      const a = entityMap[e.from], b = entityMap[e.to];
      let dx = b.x - a.x, dy = b.y - a.y;
      let dist = Math.sqrt(dx*dx + dy*dy) || 0.01;
      let force = (dist - SPRING_LENGTH) * SPRING_STRENGTH;
      let fx = (dx/dist)*force, fy = (dy/dist)*force;
      a.vx += fx; a.vy += fy; b.vx -= fx; b.vy -= fy;
    });
    nodes.forEach(n => {
      if (n.dragging) return;
      n.vx += (W/2 - n.x) * CENTER_PULL; n.vy += (H/2 - n.y) * CENTER_PULL;
      n.vx *= DAMPING; n.vy *= DAMPING; n.x += n.vx; n.y += n.vy;
    });
  }

  function draw() {
    visibleEdges.forEach(e => {
      const key = [e.from, e.to].sort().join('|');
      const line = edgeLineMap[key]; if (!line) return;
      const a = entityMap[e.from], b = entityMap[e.to];
      line.setAttribute('x1', a.x); line.setAttribute('y1', a.y);
      line.setAttribute('x2', b.x); line.setAttribute('y2', b.y);
    });
    revealed.forEach(id => {
      const entity = entityMap[id];
      const { shape, label } = nodeShapeMap[id];
      shape.setAttribute('cx', entity.x); shape.setAttribute('cy', entity.y);
      label.setAttribute('x', entity.x); label.setAttribute('y', entity.y + 30);
    });
  }

  function animate() {
    if (revealed.size > 0) { simulationStep(); draw(); }
    requestAnimationFrame(animate);
  }

  let dragNode = null, dragOffset = { x: 0, y: 0 };
  function startDrag(evt, entity) {
    dragNode = entity; entity.dragging = true;
    const pt = toSvgCoords(evt);
    dragOffset.x = pt.x - entity.x; dragOffset.y = pt.y - entity.y;
    evt.stopPropagation();
  }
  function toSvgCoords(evt) {
    const rect = svg.getBoundingClientRect();
    return { x: (evt.clientX - rect.left) * (W / rect.width), y: (evt.clientY - rect.top) * (H / rect.height) };
  }
  document.addEventListener('mousemove', evt => {
    if (!dragNode) return;
    const pt = toSvgCoords(evt);
    dragNode.x = pt.x - dragOffset.x; dragNode.y = pt.y - dragOffset.y;
    dragNode.vx = 0; dragNode.vy = 0;
  });
  document.addEventListener('mouseup', () => { if (dragNode) dragNode.dragging = false; dragNode = null; });

  resetBtn.addEventListener('click', () => startGraph(startId));

  startGraph(startId);
  animate();
})();
</script>
HTML

$html =~ s/__ENTITIES_JSON__/$entities_json/;
$html =~ s/__ADJACENCY_JSON__/$adjacency_json/;
$html =~ s/__START_ID_JSON__/$start_id_json/;

print $html;