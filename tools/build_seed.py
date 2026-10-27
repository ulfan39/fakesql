#!/usr/bin/env python3
"""Builds db/05_seed_data.sql (lookup data) for the FakeSQL library.

Word lists come from the open-source Python `faker` package (names, cities)
plus hand-written lists (street words, patterns, domains, ...).  This script
is only a ONE-TIME data loader: all generation of fake users happens in SQL.

    pip install faker
    python tools/build_seed.py > db/05_seed_data.sql
"""
import sys
from faker.providers.person.en_US import Provider as EnPerson
from faker.providers.person.de_DE import Provider as DePerson
from faker.providers.address.de_DE import Provider as DeAddress

out = []
def esc(v):
    return str(v).replace("\\", "\\\\").replace("\t", " ").replace("\n", " ")

def sql_lit(v):
    if isinstance(v, (int, float)):
        return repr(v)
    return "'" + str(v).replace("'", "''") + "'"

def copy(table, cols, rows, chunk=400):
    """Emits plain multi-row INSERTs (work with psql, psycopg, any client)."""
    for i in range(0, len(rows), chunk):
        part = rows[i:i + chunk]
        out.append(f"INSERT INTO {table} ({', '.join(cols)}) VALUES")
        out.append(",\n".join("(" + ", ".join(sql_lit(x) for x in r) + ")" for r in part) + ";")

def weighted(seq):
    """faker lists are either plain lists or OrderedDict(name -> weight)."""
    if isinstance(seq, dict):
        return [(k, float(v)) for k, v in seq.items()]
    return [(k, 1.0) for k in seq]

def uniq(seq):
    seen, res = set(), []
    for k, w in seq:
        if k not in seen:
            seen.add(k); res.append((k, w))
    return res

# ---------------------------------------------------------------- locales
copy("fk.locales", ["code", "title", "postcode_pattern", "house_number_max"], [
    ("en_US", "English (USA)", "#####", 9999),
    ("de_DE", "Deutsch (Deutschland)", "#####", 120),
])
copy("fk.translit", ["locale", "src", "dst"], [
    ("de_DE", "ä", "ae"), ("de_DE", "ö", "oe"), ("de_DE", "ü", "ue"), ("de_DE", "ß", "ss"),
])

# ---------------------------------------------------------------- names
names = []
for loc, P in (("en_US", EnPerson), ("de_DE", DePerson)):
    for k, w in uniq(weighted(P.first_names_male)):   names.append((loc, "first", "M", k, w))
    for k, w in uniq(weighted(P.first_names_female)): names.append((loc, "first", "F", k, w))
    for k, w in uniq(weighted(P.last_names)):         names.append((loc, "last", "U", k, w))
copy("fk.names", ["locale", "kind", "gender", "value", "weight"], names)

en_last = [k for k, w in uniq(weighted(EnPerson.last_names))]
de_last = [k for k, w in uniq(weighted(DePerson.last_names))]

# ---------------------------------------------------------------- lexicon
lex = []   # (locale, kind, sub, value, extra, weight)
def add(loc, kind, items, sub="", extra=""):
    for it in items:
        v, w = it if isinstance(it, tuple) else (it, 1)
        lex.append((loc, kind, sub, v, extra, w))

# titles
add("en_US", "title", [("Mr.", 90), ("Dr.", 8), ("Prof.", 2)], "M")
add("en_US", "title", [("Ms.", 60), ("Mrs.", 30), ("Dr.", 8), ("Prof.", 2)], "F")
add("de_DE", "title", [("Herr", 80), ("Dr.", 15), ("Prof. Dr.", 5)], "M")
add("de_DE", "title", [("Frau", 80), ("Dr.", 15), ("Prof. Dr.", 5)], "F")

# name patterns
add("en_US", "name_pattern", [("{first} {last}", 45), ("{title} {first} {last}", 20),
    ("{first} {middle} {last}", 18), ("{first} {mi}. {last}", 7),
    ("{title} {first} {middle} {last}", 5), ("{last}, {first}", 3), ("{first} {last} Jr.", 2)])
add("de_DE", "name_pattern", [("{first} {last}", 48), ("{title} {first} {last}", 22),
    ("{first} {middle} {last}", 14), ("{title} {first} {middle} {last}", 5),
    ("{first} {last}-{last2}", 6), ("{last}, {first}", 3), ("{title} {last}", 2)])

# streets
en_bases = """Main Oak Maple Cedar Pine Elm Washington Lake Hill Park Walnut Sunset Lincoln Jackson Church
Spring River Highland Ridge Meadow Forest Franklin Jefferson Madison Adams Monroe Cherry Willow Birch Chestnut
Dogwood Magnolia Poplar Sycamore Hickory Aspen Valley Mill Center Union Market Broad Prospect Locust Orchard
College School Railroad Bridge Garden Lakeview Sunrise Hillcrest Brookside Cottage Pleasant Liberty Colonial
Mountain Summit Canyon Prairie Harbor Bay Ocean Beach Hamilton Jefferson Roosevelt Kennedy Wilson Grant Lee
Johnson Clinton Cleveland Taylor Harrison Tyler Polk Pierce Buchanan Hayes Garfield Arthur Cypress Laurel
Holly Ivy Hawthorne Juniper Redwood Spruce Sequoia Mulberry Chapel Cemetery Water Mill Creek Fairview
Greenwood Woodland Sherwood Brookfield Stonegate Windsor Kingston Oxford Cambridge Dover Richmond Heritage""".split()
ordinal = lambda n: f"{n}{'th' if 10<=n%100<=20 else {1:'st',2:'nd',3:'rd'}.get(n%10,'th')}"
add("en_US", "street_base", [(b, 6) for b in dict.fromkeys(en_bases)])
add("en_US", "street_base", [(ordinal(n), 3) for n in range(1, 61)])
add("en_US", "street_base", [(n, 1) for n in en_last])
add("en_US", "street_type", [("Street",40),("Avenue",12),("Road",10),("Drive",10),("Lane",7),("Court",4),
    ("Boulevard",4),("Way",4),("Place",3),("Circle",2),("Trail",2),("Terrace",1),("Parkway",1)])

de_bases = """Haupt Bahnhof Schul Garten Berg Linden Kirch Wald Feld Wiesen Rosen Birken Eichen Buchen Tannen Mühlen
Markt Dorf Park Wasser Sonnen Fichten Ahorn Kastanien Erlen Lärchen Akazien Nelken Tulpen Veilchen Ring Tal
Hang Höhen Wein Brunnen Burg Schloss Kloster Rathaus Post Gerber Schmiede Bäcker Metzger Fischer Jäger Hirten
Gärtner Mühl Bach Fluss Teich See Hafen Brücken Damm Ufer Au Heide Moor Sand Stein Eisen Kohl Lehm Kalk
Goethe Schiller Lessing Mozart Beethoven Bach Kant Hegel Humboldt Bismarck Kolping Luther Heine Herder
Wagner Brahms Haydn Händel Schubert Schumann Mendelssohn Gutenberg Kepler Leibniz Einstein Röntgen Diesel
Daimler Bosch Siemens Nord Süd Ost West Neu Alt Ober Unter Kurz Lang Breit Schmal Hinter Vorder Mittel""".split()
add("de_DE", "street_base", [(b, 6) for b in dict.fromkeys(de_bases)])
add("de_DE", "street_base", [(n, 1) for n in de_last])
add("de_DE", "street_type", [("straße",60),("weg",15),("allee",4),("platz",4),("gasse",5),("ring",3),
    ("damm",2),("ufer",2),("steig",1),("pfad",1),("hof",1)], extra="glued")

# address patterns
add("en_US", "address_pattern", [("{num} {street}, {city}, {region} {zip}", 55),
    ("{num} {street}, Apt {unit}, {city}, {region} {zip}", 20),
    ("{num} {street}, Suite {unit}, {city}, {region} {zip}", 8),
    ("{num} {street} #{unit}, {city}, {region} {zip}", 7),
    ("{num} {street}, {city}, {region}", 10)])
add("de_DE", "address_pattern", [("{street} {num}, {zip} {city}", 55),
    ("{street} {num}{letter}, {zip} {city}", 15),
    ("{street} {num}, {floor}. OG, {zip} {city}", 12),
    ("{zip} {city}, {street} {num}", 8),
    ("{street} {num}, Wohnung {unit}, {zip} {city}", 10)])

# cities (real places; extra = region)
us_cities = """New York,NY|Los Angeles,CA|Chicago,IL|Houston,TX|Phoenix,AZ|Philadelphia,PA|San Antonio,TX|San Diego,CA|Dallas,TX|San Jose,CA
Austin,TX|Jacksonville,FL|Fort Worth,TX|Columbus,OH|Charlotte,NC|San Francisco,CA|Indianapolis,IN|Seattle,WA|Denver,CO|Washington,DC
Boston,MA|El Paso,TX|Nashville,TN|Detroit,MI|Oklahoma City,OK|Portland,OR|Las Vegas,NV|Memphis,TN|Louisville,KY|Baltimore,MD
Milwaukee,WI|Albuquerque,NM|Tucson,AZ|Fresno,CA|Mesa,AZ|Sacramento,CA|Atlanta,GA|Kansas City,MO|Colorado Springs,CO|Omaha,NE
Raleigh,NC|Miami,FL|Long Beach,CA|Virginia Beach,VA|Oakland,CA|Minneapolis,MN|Tulsa,OK|Tampa,FL|Arlington,TX|New Orleans,LA
Wichita,KS|Cleveland,OH|Bakersfield,CA|Aurora,CO|Anaheim,CA|Honolulu,HI|Santa Ana,CA|Riverside,CA|Corpus Christi,TX|Lexington,KY
Henderson,NV|Stockton,CA|Saint Paul,MN|Cincinnati,OH|St. Louis,MO|Pittsburgh,PA|Greensboro,NC|Lincoln,NE|Anchorage,AK|Plano,TX
Orlando,FL|Irvine,CA|Newark,NJ|Durham,NC|Chula Vista,CA|Toledo,OH|Fort Wayne,IN|St. Petersburg,FL|Laredo,TX|Jersey City,NJ
Chandler,AZ|Madison,WI|Lubbock,TX|Scottsdale,AZ|Reno,NV|Buffalo,NY|Gilbert,AZ|Glendale,AZ|Winston-Salem,NC|Chesapeake,VA
Norfolk,VA|Fremont,CA|Garland,TX|Irving,TX|Hialeah,FL|Richmond,VA|Boise,ID|Spokane,WA|Baton Rouge,LA|Tacoma,WA
San Bernardino,CA|Modesto,CA|Fontana,CA|Des Moines,IA|Moreno Valley,CA|Santa Clarita,CA|Fayetteville,NC|Birmingham,AL|Oxnard,CA|Rochester,NY
Port St. Lucie,FL|Grand Rapids,MI|Huntsville,AL|Salt Lake City,UT|Frisco,TX|Yonkers,NY|Amarillo,TX|Glendale,CA|Huntington Beach,CA|McKinney,TX
Montgomery,AL|Augusta,GA|Akron,OH|Little Rock,AR|Tempe,AZ|Columbus,GA|Overland Park,KS|Grand Prairie,TX|Tallahassee,FL|Cape Coral,FL
Mobile,AL|Knoxville,TN|Shreveport,LA|Worcester,MA|Ontario,CA|Vancouver,WA|Sioux Falls,SD|Chattanooga,TN|Brownsville,TX|Fort Lauderdale,FL
Providence,RI|Newport News,VA|Rancho Cucamonga,CA|Santa Rosa,CA|Peoria,AZ|Oceanside,CA|Elk Grove,CA|Salem,OR|Pembroke Pines,FL|Eugene,OR
Garden Grove,CA|Cary,NC|Fort Collins,CO|Corona,CA|Springfield,MO|Jackson,MS|Alexandria,VA|Hayward,CA|Clarksville,TN|Lakewood,CO
Lancaster,CA|Salinas,CA|Palmdale,CA|Hollywood,FL|Springfield,IL|Macon,GA|Sunnyvale,CA|Pomona,CA|Killeen,TX|Escondido,CA
Pasadena,TX|Naperville,IL|Bellevue,WA|Joliet,IL|Murfreesboro,TN|Midland,TX|Rockford,IL|Paterson,NJ|Savannah,GA|Bridgeport,CT
Torrance,CA|McAllen,TX|Syracuse,NY|Surprise,AZ|Denton,TX|Roseville,CA|Thornton,CO|Miramar,FL|Mesquite,TX|Olathe,KS
Dayton,OH|Carrollton,TX|Waco,TX|Orange,CA|Fullerton,CA|Charleston,SC|West Valley City,UT|Visalia,CA|Hampton,VA|Gainesville,FL
Warren,MI|Coral Springs,FL|Cedar Rapids,IA|Round Rock,TX|Sterling Heights,MI|Kent,WA|Columbia,SC|Santa Clara,CA|New Haven,CT|Stamford,CT
Concord,CA|Elizabeth,NJ|Athens,GA|Thousand Oaks,CA|Lafayette,LA|Simi Valley,CA|Topeka,KS|Norman,OK|Fargo,ND|Wilmington,NC
Abilene,TX|Odessa,TX|Pearland,TX|Victorville,CA|Hartford,CT|Vallejo,CA|Allentown,PA|Berkeley,CA|Richardson,TX|Arvada,CO
Ann Arbor,MI|Cambridge,MA|Sugar Land,TX|Lansing,MI|Evansville,IN|College Station,TX|Fairfield,CA|Clearwater,FL|Beaumont,TX|Independence,MO
Provo,UT|West Jordan,UT|Murrieta,CA|Palm Bay,FL|El Monte,CA|Carlsbad,CA|Charleston,WV|Temecula,CA|Clovis,CA|Meridian,ID
Westminster,CO|Costa Mesa,CA|High Point,NC|Manchester,NH|Pueblo,CO|Lakeland,FL|Pompano Beach,FL|West Palm Beach,FL|Antioch,CA|Everett,WA
Downey,CA|Lowell,MA|Centennial,CO|Elgin,IL|Broken Arrow,OK|Miami Gardens,FL|Billings,MT|Jurupa Valley,CA|Sandy Springs,GA|Gresham,OR
Lewisville,TX|Hillsboro,OR|Ventura,CA|Greeley,CO|Inglewood,CA|Waterbury,CT|League City,TX|Santa Maria,CA|Tyler,TX|Davie,FL
Daly City,CA|Boulder,CO|Allen,TX|West Covina,CA|Sparks,NV|Wichita Falls,TX|Green Bay,WI|San Mateo,CA|Norwalk,CA|Rialto,CA""".replace("\n", "|").split("|")
seen = set()
for i, c in enumerate(us_cities):
    city, st = c.rsplit(",", 1)
    if (city, st) in seen: continue
    seen.add((city, st))
    add("en_US", "city", [(city, 8 if i < 30 else 3 if i < 100 else 1)], extra=st)
de_cities = [c for c, w in uniq(weighted(DeAddress.cities))]
add("de_DE", "city", [(c, 1) for c in de_cities])
for c, w in [("Berlin", 40), ("Hamburg", 25), ("München", 25), ("Köln", 20), ("Frankfurt am Main", 15),
             ("Stuttgart", 12), ("Düsseldorf", 12), ("Leipzig", 10), ("Dortmund", 9), ("Essen", 9)]:
    add("de_DE", "city", [(c, w)])

# phone / e-mail
add("en_US", "phone_pattern", [("(N##) N##-####", 38), ("N##-N##-####", 25), ("+1 N## N##-####", 15),
                               ("N##.N##.####", 10), ("1-N##-N##-####", 7), ("+1 (N##) N##-####", 5)])
add("de_DE", "phone_pattern", [("+49 17# #######", 22), ("01## #######", 20), ("+49 N## #######", 15),
                               ("0N## ######", 15), ("0N## / ######", 8), ("+49 15## ########", 10), ("0N#### ######", 10)])
mail_pats = [("{first}.{last}", 35), ("{first}{last}", 12), ("{f}{last}", 12), ("{first}_{last}", 10),
             ("{last}.{first}", 8), ("{first}.{last}{nn}", 10), ("{first}{yy}", 5), ("{f}.{last}", 8)]
add("en_US", "email_pattern", mail_pats); add("de_DE", "email_pattern", mail_pats)
add("en_US", "email_domain", [("gmail.com",45),("yahoo.com",15),("outlook.com",12),("hotmail.com",8),
    ("icloud.com",8),("aol.com",3),("proton.me",3),("comcast.net",3),("example.com",3)])
add("de_DE", "email_domain", [("gmail.com",25),("web.de",20),("gmx.de",20),("t-online.de",15),
    ("outlook.de",7),("yahoo.de",5),("gmx.net",5),("icloud.com",3)])

# eye colours
add("en_US", "eye_color", [("Brown",45),("Blue",27),("Hazel",18),("Green",9),("Gray",1)])
add("de_DE", "eye_color", [("Blue",40),("Brown",30),("Green",15),("Gray",8),("Hazel",7)])

copy("fk.lexicon", ["locale", "kind", "sub", "value", "extra", "weight"], lex)

copy("fk.body_stats", ["locale", "gender", "height_mean", "height_sd", "weight_mean", "weight_sd"], [
    ("en_US", "M", 175.3, 7.6, 89.7, 15.0), ("en_US", "F", 161.5, 7.1, 77.0, 15.0),
    ("de_DE", "M", 180.3, 7.2, 85.0, 12.5), ("de_DE", "F", 166.2, 6.8, 69.0, 12.0),
])
out.append("CALL fk.refresh_pools();")
sys.stdout.write("-- generated by tools/build_seed.py; do not edit by hand\n" + "\n".join(out) + "\n")
