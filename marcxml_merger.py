#!/usr/bin/env python3
"""
Führt mehrere MARCXML-Dateien (jede mit genau einem <record>) zu einer
einzigen MARCXML-Datei mit <collection> zusammen.

Verwendung:
    python merge_marcxml.py <eingabe_ordner> <ausgabe_datei.xml>

Beispiel:
    python merge_marcxml.py ./marc_records ./alle_records.xml
"""

import sys
import glob
import os
from lxml import etree

MARC_NS = "http://www.loc.gov/MARC21/slim"
NSMAP = {"marc": MARC_NS}


def find_record_elements(root):
    """Findet alle <record>-Elemente, egal ob mit oder ohne Namespace,
    egal ob root selbst schon ein record oder eine collection ist."""
    # Fall 1: root ist bereits ein <record>
    tag = etree.QName(root).localname
    if tag == "record":
        return [root]

    # Fall 2: root ist eine <collection> (oder etwas anderes) -> record-Kinder suchen
    records = root.findall(".//marc:record", namespaces=NSMAP)
    if not records:
        # Falls die Datei ganz ohne Namespace vorliegt
        records = root.findall(".//record")
    return records


def merge_marcxml(input_dir, output_file):
    files = sorted(glob.glob(os.path.join(input_dir, "*.marcxml")))
    if not files:
        print(f"Keine .xml-Dateien in '{input_dir}' gefunden.")
        sys.exit(1)

    collection = etree.Element("{%s}collection" % MARC_NS, nsmap={None: MARC_NS})

    count = 0
    errors = []

    for filepath in files:
        try:
            tree = etree.parse(filepath)
            root = tree.getroot()
            records = find_record_elements(root)

            if not records:
                errors.append(f"Kein <record> gefunden in: {filepath}")
                continue

            for record in records:
                collection.append(record)
                count += 1

        except etree.XMLSyntaxError as e:
            errors.append(f"Fehler beim Parsen von {filepath}: {e}")

    out_tree = etree.ElementTree(collection)
    out_tree.write(
        output_file,
        pretty_print=True,
        xml_declaration=True,
        encoding="UTF-8",
    )

    print(f"Fertig: {count} Records aus {len(files)} Dateien in '{output_file}' geschrieben.")
    if errors:
        print(f"\n{len(errors)} Problem(e) aufgetreten:")
        for err in errors:
            print(f"  - {err}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Verwendung: python merge_marcxml.py <eingabe_ordner> <ausgabe_datei.xml>")
        sys.exit(1)

    merge_marcxml(sys.argv[1], sys.argv[2])