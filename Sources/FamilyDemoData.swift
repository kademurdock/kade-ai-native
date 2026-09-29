import Foundation

// MARK: - The made-up demo family (DEBUG builds only)
//
// Every answer the Family history screens ask for, from the website's own
// fictional fixture family ("Ada Example" and her relatives in Invented
// County). Nobody here is real. Release builds do not contain this file's
// contents at all (Kade, Sep 29: no made-up-family preview in Release), so
// App Review and unmatched accounts meet only the greyed Library row.
//
// Used by:
//   - the -KadeFamilyDemo launch argument (or KADE_FAMILY_DEMO=1), for the
//     tour, the accessibility audit and previews: the family screens open
//     with these answers and never touch the network;
//   - run-family-tests.sh, which decodes every answer here, so a model that
//     no longer reads the shapes fails the gate.
//
// The website's dump-native-fixtures.ts will write this file from the same
// fixture once it exists; until then it is kept by hand, in the shapes of
// DESIGN section 3.1. Pictures are initials only (no links).

#if DEBUG
enum FamilyDemoData {
    /// The answer for one API path (after "api/kade/family-history/"), or
    /// nil for a 404.
    static func payload(path: String, query: [String: String] = [:]) -> String? {
        if path.hasPrefix("person/") {
            switch String(path.dropFirst("person/".count)) {
            case "@I300@": return personDan
            case "@I400@": return personHugo
            default: return nil
            }
        }
        if path.hasPrefix("story/") {
            return path == "story/the-farm" ? story : nil
        }
        if path.hasPrefix("media/") {
            if path == "media/sign" { return signed }
            if path == "media/m-tree1/info" { return mediaInfo }
            return nil
        }
        switch path {
        case "me": return me
        case "home": return home
        case "tree": return tree
        case "gallery": return gallery
        case "dna": return dna
        case "timeline": return timeline
        case "places": return places
        case "stories": return stories
        case "findings": return query["group"] == "mysteries" ? mysteries : findings
        case "play": return play
        case "people": return people
        case "search": return search
        case "note": return noteSent
        default: return nil
        }
    }

    // MARK: People (the viewer is Jack Example, the owner's brother)

    static let jack = ##"{"id":"@I101@","name":"Jack Example","first":"Jack","years":"born 1992","yearsSpoken":"born 1992","living":true,"gen":0,"term":"you","chain":null,"side":"both","sideText":"You","research":null,"face":null,"initials":"JE","spoken":"You, Jack Example, born 1992."}"##
    static let ada = ##"{"id":"@I100@","name":"Ada Example","first":"Ada","years":"born 1990","yearsSpoken":"born 1990","living":true,"gen":0,"term":"your sister","chain":null,"side":"both","sideText":"Both sides","research":null,"face":null,"initials":"AE","spoken":"Your sister, Ada Example, born 1990, both sides."}"##
    static let kit = ##"{"id":"@I102@","name":"Kit Example","first":"Kit","years":"1985–2019","yearsSpoken":"1985 to 2019","living":false,"gen":0,"term":"your half brother","chain":null,"side":"father","sideText":"Dad's side","research":null,"face":null,"initials":"KE","spoken":"Your half brother, Kit Example, 1985 to 2019, Dad's side."}"##
    static let maxExample = ##"{"id":"@I120@","name":"Max Example","first":"Max","years":"born 2015","yearsSpoken":"born 2015","living":true,"gen":-1,"term":"your nephew","chain":"your sister's son","side":"both","sideText":"Both sides","research":null,"face":null,"initials":"ME","spoken":"Your nephew, Max Example, born 2015."}"##
    static let lee = ##"{"id":"@I110@","name":"Lee Spouse","first":"Lee","years":"born 1989","yearsSpoken":"born 1989","living":true,"gen":null,"term":"your brother-in-law","chain":"your sister's husband","side":"marriage","sideText":"By marriage","research":null,"face":null,"initials":"LS","spoken":"Your brother-in-law, Lee Spouse, born 1989, by marriage."}"##
    static let ben = ##"{"id":"@I200@","name":"Ben Example","first":"Ben","years":"1960–2020","yearsSpoken":"1960 to 2020","living":false,"gen":1,"term":"your father","chain":"your dad","side":"father","sideText":"Dad's side","research":null,"face":null,"initials":"BE","spoken":"Your father, Ben Example, 1960 to 2020, Dad's side."}"##
    static let cora = ##"{"id":"@I201@","name":"Cora Example","first":"Cora","years":"born 1962","yearsSpoken":"born 1962","living":true,"gen":1,"term":"your mother","chain":"your mom","side":"mother","sideText":"Mom's side","research":null,"face":null,"initials":"CE","bornA":"born a Sample","otherNames":["Cora Sample"],"spoken":"Your mother, Cora Example, born a Sample, born 1962, Mom's side."}"##
    static let ned = ##"{"id":"@I210@","name":"Ned Example","first":"Ned","years":"1958–2018","yearsSpoken":"1958 to 2018","living":false,"gen":null,"term":"your uncle","chain":"your dad's brother","side":"father","sideText":"Dad's side","research":null,"face":null,"initials":"NE","spoken":"Your uncle, Ned Example, 1958 to 2018, Dad's side."}"##
    static let opal = ##"{"id":"@I211@","name":"Opal Example","first":"Opal","years":"1959–2021","yearsSpoken":"1959 to 2021","living":false,"gen":null,"term":"your uncle's wife","chain":null,"side":"marriage","sideText":"By marriage","research":null,"face":null,"initials":"OE","spoken":"Your uncle's wife, Opal Example, 1959 to 2021, by marriage."}"##
    static let dan = ##"{"id":"@I300@","name":"Dan Example","first":"Dan","years":"1930–1999","yearsSpoken":"1930 to 1999","living":false,"gen":2,"term":"your grandfather","chain":"your dad's dad","side":"father","sideText":"Dad's side","research":null,"face":null,"initials":"DE","spoken":"Your grandfather, Dan Example, 1930 to 1999, Dad's side."}"##
    static let eve = ##"{"id":"@I301@","name":"Eve Example","first":"Eve","years":"1932–2010","yearsSpoken":"1932 to 2010","living":false,"gen":2,"term":"your grandmother","chain":"your dad's mom","side":"father","sideText":"Dad's side","research":null,"face":null,"initials":"EE","spoken":"Your grandmother, Eve Example, 1932 to 2010, Dad's side."}"##
    static let finn = ##"{"id":"@I302@","name":"Finn Sample","first":"Finn","years":"1935–2001","yearsSpoken":"1935 to 2001","living":false,"gen":2,"term":"your grandfather","chain":"your mom's dad","side":"mother","sideText":"Mom's side","research":null,"face":null,"initials":"FS","spoken":"Your grandfather, Finn Sample, 1935 to 2001, Mom's side."}"##
    static let gail = ##"{"id":"@I303@","name":"Gail Sample","first":"Gail","years":"1936–2015","yearsSpoken":"1936 to 2015","living":false,"gen":2,"term":"your grandmother","chain":"your mom's mom","side":"mother","sideText":"Mom's side","research":null,"face":null,"initials":"GS","spoken":"Your grandmother, Gail Sample, 1936 to 2015, Mom's side."}"##
    static let hugo = ##"{"id":"@I400@","name":"Hugo Example","first":"Hugo","years":"1900–1970","yearsSpoken":"1900 to 1970","living":false,"gen":3,"term":"your great-grandfather","chain":"your dad's dad's dad","side":"father","sideText":"Dad's side","research":null,"face":null,"initials":"HE","spoken":"Your great-grandfather, Hugo Example, 1900 to 1970, Dad's side."}"##
    static let ivo = ##"{"id":"@I500@","name":"Ivo Example","first":"Ivo","years":"1870–1940","yearsSpoken":"1870 to 1940","living":false,"gen":4,"term":"your 2nd great-grandfather","chain":null,"side":"father","sideText":"Dad's side","research":null,"face":null,"initials":"IE","spoken":"Your 2nd great-grandfather, Ivo Example, 1870 to 1940, Dad's side."}"##
    static let unknown = ##"{"id":"@I700@","name":"Name not known, identified by DNA as a son of the Sample family","first":null,"years":"about 1900","yearsSpoken":"about 1900","living":false,"gen":3,"term":"your great-grandfather","chain":"your mom's dad's dad","side":"mother","sideText":"Mom's side","research":{"level":"dna","text":"Strong DNA evidence (about 90–95% sure)"},"face":null,"initials":"NK","spoken":"Your great-grandfather, name not known, identified by DNA as a son of the Sample family, Mom's side. Research finding, strong DNA evidence, about 90 to 95 percent sure, not proven by records."}"##

    // MARK: Pictures (no links: the demo draws initials and labels)

    static let photoDan = ##"{"id":"m-tree1","category":"photo","w":640,"h":480,"year":1955,"thumb":null,"face":null,"short":"Photo: your grandfather, Dan Example","alt":"Photo: your grandfather, Dan Example, about 1955. A man in a work shirt on the steps of an invented porch.","description":"A man in a work shirt stands on the steps of a wooden porch with one hand on the rail. Behind him a screen door is half open. Made up for the demo family.","date":"about 1955","place":"Invented County","described":"auto","hasText":false,"textAuto":false,"shareable":true,"restored":"m-tree1r","restoredLabel":"Restored with AI: colours and repairs may be guessed","caption":"Dan Example on an invented porch"}"##
    static let photoDanRestored = ##"{"id":"m-tree1r","category":"restored","w":640,"h":480,"year":1955,"thumb":null,"face":null,"short":"Photo restored with AI: your grandfather, Dan Example","alt":"Photo restored with AI: your grandfather, Dan Example, about 1955. A man in a work shirt on the steps of an invented porch.","description":"The same photo with its scratches mended and its colours guessed. Made up for the demo family.","date":"about 1955","place":"Invented County","described":"auto","hasText":false,"textAuto":false,"shareable":true,"restoredFrom":"m-tree1","restoredLabel":"Restored with AI: colours and repairs may be guessed","caption":"Dan Example on an invented porch (restored with AI)"}"##
    static let graveDan = ##"{"id":"m-grave1","category":"grave","w":480,"h":640,"year":1999,"thumb":null,"face":null,"short":"Grave photo: your grandfather, Dan Example","alt":"Grave photo: your grandfather, Dan Example, 1999. A grey upright stone in short grass.","description":"A plain grey upright stone with a rounded top stands in short grass. Made up for the demo family.","date":"1999","place":"Invented Cemetery, Invented County","described":"auto","hasText":true,"textAuto":true,"shareable":true,"caption":"Headstone"}"##
    static let recordDan = ##"{"id":"m-rec1","category":"record","w":1600,"h":1200,"year":1950,"thumb":null,"face":null,"short":"Record scan: 1950 census for your grandfather, Dan Example","alt":"Record scan: an invented 1950 census page for your grandfather, Dan Example.","description":null,"date":"1950","place":"Invented County","described":null,"hasText":false,"textAuto":false,"shareable":true,"caption":"Invented census page"}"##

    // MARK: GET /me

    static let me = ##"""
{"access":true,"mode":"family","isOwner":false,"version":"demo-1",
 "viewer":{"personId":"@I101@","first":"Jack","name":"Jack Example"},
 "owner":{"first":"Ada"},
 "row":{"detail":"Ada's brother","hint":"Your place in the family tree, with photos, records, a map and stories."},
 "viewNote":null}
"""##

    // MARK: GET /home

    static let home = ##"""
{"version":"demo-1","mode":"family","isOwner":false,
 "hero":{"hello":"Hi Jack.","headline":"Your family goes back to 1870.","youAre":"You're Ada's brother.",
  "stats":"18 people in the tree, 11 of them your direct ancestors.","follows":null,
  "spoken":"Hi Jack. Your family goes back to 1870. You're Ada's brother. 18 people in the tree, 11 of them your direct ancestors.",
  "open":{"to":"tree"}},
 "faces":{"layout":"row","people":[\##(dan),\##(eve),\##(finn),\##(gail),\##(hugo)],"portrait":null},
 "reel":{"title":"Your family in 60 seconds","detail":"5 cards, about a minute","cover":\##(photoDan),
  "cards":[
   {"key":"you","images":[],"people":[\##(jack)],"text":"It starts with you, Jack.","spoken":"It starts with you, Jack.","open":{"to":"tree"}},
   {"key":"grandparents","images":[],"people":[\##(dan),\##(eve),\##(finn),\##(gail)],"text":"Your four grandparents: Dan, Eve, Finn and Gail.","spoken":"Your four grandparents: Dan, Eve, Finn and Gail.","open":null},
   {"key":"oldest","images":[],"people":[\##(ivo)],"text":"Your oldest known ancestor, Ivo Example, was born in 1870.","spoken":"Your oldest known ancestor, Ivo Example, was born in 1870.","open":{"to":"person","id":"@I500@","name":"Ivo Example"}},
   {"key":"places","images":[],"people":[],"text":"Most of them lived in Invented County.","spoken":"Most of them lived in Invented County.","open":{"to":"whereWhen"}},
   {"key":"end","images":[],"people":[],"text":"Explore your tree.","spoken":"Explore your tree.","open":{"to":"tree"}}]},
 "featured":[
  {"kind":"ancestorOfWeek","title":"Ancestor of the week","text":"Your great-grandfather Hugo Example, 1900–1970, kept the farm on Example Road.","spoken":"Ancestor of the week: your great-grandfather Hugo Example, 1900 to 1970, kept the farm on Example Road.","image":null,"open":{"to":"person","id":"@I400@","name":"Hugo Example"}},
  {"kind":"story","title":"A family story","text":"The farm on Example Road, about 2 minutes.","spoken":"A family story: The farm on Example Road, about 2 minutes.","image":null,"open":{"to":"story","id":"the-farm","title":"The farm on Example Road"}}],
 "news":{"text":"1 new photo and 2 new people since your last visit","spoken":"1 new photo and 2 new people since your last visit.","images":[\##(photoDan)],"open":{"to":"gallery","filter":"photos","since":"demo-0"}},
 "tiles":[
  {"key":"tree","title":"Your family tree","detail":"You and 4 generations up","spoken":"Your family tree, you and 4 generations up","hint":"Opens the tree, starting with you.","enabled":true,"reason":null,"open":{"to":"tree"}},
  {"key":"photos","title":"Photos","detail":"2 photos, plus records and graves","spoken":"Photos, 2 photos, plus records and graves","hint":"Opens the family's photos, nearest relatives first.","enabled":true,"reason":null,"open":{"to":"gallery","filter":"photos"}},
  {"key":"whereWhen","title":"Where and when","detail":"Through the years, and on a map","spoken":"Where and when, through the years, and on a map","hint":"Opens a timeline of the family, decade by decade.","enabled":true,"reason":null,"open":{"to":"whereWhen"}},
  {"key":"dna","title":"Ada's DNA test counts for you too","detail":"What it found about your family","spoken":"Ada's DNA test counts for you too, what it found about your family","hint":"Opens your family's DNA, in plain words.","enabled":true,"reason":null,"open":{"to":"dna"}}],
 "more":[
  {"key":"stories","title":"Stories","detail":"1 story","spoken":"Stories, 1 story","hint":"Family stories to read or hear.","enabled":true,"reason":null,"open":{"to":"stories"}},
  {"key":"discoveries","title":"Discoveries","detail":"1 discovery","spoken":"Discoveries, 1 discovery","hint":"What the research found.","enabled":true,"reason":null,"open":{"to":"discoveries"}},
  {"key":"mysteries","title":"Family mysteries","detail":"About who one ancestor's father was","spoken":"Family mysteries, about who one ancestor's father was","hint":"Opens behind a heads-up.","enabled":true,"reason":null,"open":{"to":"mysteries"}},
  {"key":"people","title":"Everyone in the tree","detail":"18 people","spoken":"Everyone in the tree, 18 people","hint":"Search the tree or browse it by generation.","enabled":true,"reason":null,"open":{"to":"people"}},
  {"key":"play","title":"How are you related?","detail":"A quick game","spoken":"How are you related? A quick game","hint":"Five questions about your family.","enabled":true,"reason":null,"open":{"to":"play"}},
  {"key":"note","title":"Add a memory","detail":"Tell Ada something she should know","spoken":"Add a memory, tell Ada something she should know","hint":"Sends a note to Ada.","enabled":true,"reason":null,"open":{"to":"note"}}],
 "comingSoon":null,
 "footnote":"Built from Ada's research: records, graves, photos and DNA. Research findings are marked.",
 "owner":null}
"""##

    // MARK: GET /tree (3 up, 1 down)

    static let tree = ##"""
{"focus":"@I101@",
 "layout":{
  "boxes":[
   {"key":"@I400@#9","id":"@I400@","gen":3,"row":0,"x":0,"role":"ancestor","repeat":false,"you":false,"person":\##(hugo),"moreAbove":1,"spoken":"Your great-grandfather, Hugo Example, 1900 to 1970, Dad's side, 1 more generation above"},
   {"key":"@I700@#10","id":"@I700@","gen":3,"row":0,"x":2,"role":"ancestor","repeat":false,"you":false,"person":\##(unknown),"moreAbove":null,"spoken":"Your great-grandfather, name not known, identified by DNA as a son of the Sample family, Mom's side. Research finding, strong DNA evidence, not proven by records."},
   {"key":"@I300@#5","id":"@I300@","gen":2,"row":1,"x":0,"role":"ancestor","repeat":false,"you":false,"person":\##(dan),"moreAbove":null,"spoken":"Your grandfather, Dan Example, 1930 to 1999, Dad's side."},
   {"key":"@I301@#6","id":"@I301@","gen":2,"row":1,"x":1,"role":"ancestor","repeat":false,"you":false,"person":\##(eve),"moreAbove":null,"spoken":"Your grandmother, Eve Example, 1932 to 2010, Dad's side."},
   {"key":"@I302@#7","id":"@I302@","gen":2,"row":1,"x":2,"role":"ancestor","repeat":false,"you":false,"person":\##(finn),"moreAbove":null,"spoken":"Your grandfather, Finn Sample, 1935 to 2001, Mom's side."},
   {"key":"@I303@#8","id":"@I303@","gen":2,"row":1,"x":3,"role":"ancestor","repeat":false,"you":false,"person":\##(gail),"moreAbove":null,"spoken":"Your grandmother, Gail Sample, 1936 to 2015, Mom's side."},
   {"key":"@I200@#3","id":"@I200@","gen":1,"row":2,"x":0.5,"role":"ancestor","repeat":false,"you":false,"person":\##(ben),"moreAbove":null,"spoken":"Your father, Ben Example, 1960 to 2020, Dad's side."},
   {"key":"@I201@#4","id":"@I201@","gen":1,"row":2,"x":2.5,"role":"ancestor","repeat":false,"you":false,"person":\##(cora),"moreAbove":null,"spoken":"Your mother, Cora Example, born 1962, Mom's side."},
   {"key":"@I102@#2","id":"@I102@","gen":0,"row":3,"x":0.5,"role":"sibling","repeat":false,"you":false,"person":\##(kit),"moreAbove":null,"spoken":"Your half brother, Kit Example, 1985 to 2019, Dad's side."},
   {"key":"@I101@#0","id":"@I101@","gen":0,"row":3,"x":1.5,"role":"focus","repeat":false,"you":true,"person":\##(jack),"moreAbove":null,"spoken":"You, Jack Example, born 1992."},
   {"key":"@I100@#1","id":"@I100@","gen":0,"row":3,"x":2.5,"role":"sibling","repeat":false,"you":false,"person":\##(ada),"moreAbove":null,"spoken":"Your sister, Ada Example, born 1990, both sides."}],
  "edges":[
   {"from":"@I400@#9","to":"@I300@#5","kind":"birth"},
   {"from":"@I700@#10","to":"@I302@#7","kind":"probable"},
   {"from":"@I300@#5","to":"@I200@#3","kind":"birth"},
   {"from":"@I301@#6","to":"@I200@#3","kind":"birth"},
   {"from":"@I302@#7","to":"@I201@#4","kind":"birth"},
   {"from":"@I303@#8","to":"@I201@#4","kind":"birth"},
   {"from":"@I200@#3","to":"@I101@#0","kind":"birth"},
   {"from":"@I201@#4","to":"@I101@#0","kind":"birth"},
   {"from":"@I200@#3","to":"@I100@#1","kind":"birth"},
   {"from":"@I201@#4","to":"@I100@#1","kind":"birth"},
   {"from":"@I200@#3","to":"@I102@#2","kind":"birth"}],
  "couples":[["@I300@#5","@I301@#6"],["@I302@#7","@I303@#8"],["@I200@#3","@I201@#4"]],
  "width":4,"rows":4,
  "order":["@I101@#0","@I200@#3","@I201@#4","@I100@#1","@I102@#2","@I300@#5","@I301@#6","@I302@#7","@I303@#8","@I400@#9","@I700@#10"],
  "extraParents":[]},
 "summary":{"text":"Centred on you. 11 people shown.","spoken":"Centred on you, Jack Example. 11 people shown."},
 "legend":[
  {"key":"birth","text":"Solid line: born to"},
  {"key":"step","text":"Dashed line: step or adoptive parent"},
  {"key":"probable","text":"Dotted line: probable or doubtful parent, a research finding"}],
 "list":[
  {"heading":"Parents","level":2,"rows":[
   {"id":"@I200@","spoken":"Your father, Ben Example, 1960 to 2020, Dad's side.","person":\##(ben)},
   {"id":"@I201@","spoken":"Your mother, Cora Example, born 1962, Mom's side.","person":\##(cora)}]},
  {"heading":"Grandparents","level":2,"rows":[
   {"id":"@I300@","spoken":"Your grandfather, Dan Example, 1930 to 1999, Dad's side.","person":\##(dan)},
   {"id":"@I301@","spoken":"Your grandmother, Eve Example, 1932 to 2010, Dad's side.","person":\##(eve)},
   {"id":"@I302@","spoken":"Your grandfather, Finn Sample, 1935 to 2001, Mom's side.","person":\##(finn)},
   {"id":"@I303@","spoken":"Your grandmother, Gail Sample, 1936 to 2015, Mom's side.","person":\##(gail)}]},
  {"heading":"Great-grandparents","level":2,"rows":[
   {"id":"@I400@","spoken":"Your great-grandfather, Hugo Example, 1900 to 1970, Dad's side.","person":\##(hugo)},
   {"id":"@I700@","spoken":"Your great-grandfather, name not known, identified by DNA as a son of the Sample family, Mom's side. Research finding, strong DNA evidence, not proven by records.","person":\##(unknown)}]},
  {"heading":"Brothers and sisters","level":2,"rows":[
   {"id":"@I100@","spoken":"Your sister, Ada Example, born 1990, both sides.","person":\##(ada)},
   {"id":"@I102@","spoken":"Your half brother, Kit Example, 1985 to 2019, Dad's side.","person":\##(kit)}]}]}
"""##

    // MARK: GET /person/:id

    static let personDan = ##"""
{"person":{"id":"@I300@","name":"Dan Example","first":"Dan","years":"1930–1999","yearsSpoken":"1930 to 1999","living":false,"gen":2,"term":"your grandfather","chain":"your dad's dad","side":"father","sideText":"Dad's side","research":null,"face":null,"initials":"DE","otherNames":["Daniel Example"],"bornA":null,"duplicate":null,"spoken":"Dan Example, 1930 to 1999. Your grandfather, Dad's side."},
 "header":\##(photoDan),"headerKind":"portrait",
 "nutshell":{"text":"Born in 1930 in Invented County. Married at 24 and raised 2 sons. Farmed on Example Road and died there at 69.","spoken":"Born in 1930 in Invented County. Married at 24 and raised 2 sons. Farmed on Example Road and died there at 69."},
 "livedThrough":"Born 1930; lived through the Depression and World War II.",
 "relation":{"term":"your grandfather","chain":"your dad's dad","ladder":["You","Dad","Grandpa"],"pathPeople":[\##(jack),\##(ben),\##(dan)],"pathText":"You, then your dad Ben Example, then his dad Dan Example.","dnaLine":"On average about 1 in 4 of your DNA comes from him. From the records, not a DNA test.","details":"Grandparents share about 25% of their DNA with a grandchild, on average."},
 "pictures":{"total":4,"items":[\##(photoDanRestored),\##(photoDan),\##(graveDan),\##(recordDan)]},
 "life":[
  {"year":1930,"text":"Born in Invented County","spoken":"1930: born in Invented County.","records":[]},
  {"year":1950,"text":"Counted in the census in Invented County, age 20","spoken":"1950: counted in the census in Invented County, age 20.","records":["c1:r1"]},
  {"year":1954,"text":"Married Eve Example","spoken":"1954: married Eve Example.","records":[]},
  {"year":1999,"text":"Died in Invented County, age 69","spoken":"1999: died in Invented County, age 69.","records":[]}],
 "family":{"parents":[\##(hugo)],"spouses":[\##(eve)],"siblings":[],"children":[\##(ben),\##(ned)]},
 "records":[
  {"key":"c1:r1","title":"1950 Invented Census, Invented County","spoken":"1950 Invented Census, Invented County, scan available, 4 fields","image":\##(recordDan),
   "fields":[["Name","Dan Example"],["Age","20"],["Relation to head","Son"],["Residence","Invented County"]],
   "household":[["Name","Relation","Age"],["Hugo Example","Head",50],["Dan Example","Son",20]],
   "url":null,"wrong":null,"scrubbed":false}],
 "grave":{"cemetery":"Invented Cemetery","place":"Invented County","dates":"1930 to 1999","inscription":"Rest well","bio":"A made-up memorial for the demo family.","photos":[\##(graveDan)],"url":null},
 "findings":[],
 "sources":[
  {"kind":"record","title":"1950 Invented Census","citation":"Invented County, page 1, line 4 (made up).","url":null},
  {"kind":"memorial","title":"Invented Cemetery memorial","citation":"A made-up memorial.","url":null}],
 "withheld":null,
 "share":{"allowed":true}}
"""##

    static let personHugo = ##"""
{"person":{"id":"@I400@","name":"Hugo Example","first":"Hugo","years":"1900–1970","yearsSpoken":"1900 to 1970","living":false,"gen":3,"term":"your great-grandfather","chain":"your dad's dad's dad","side":"father","sideText":"Dad's side","research":null,"face":null,"initials":"HE","otherNames":[],"bornA":null,"duplicate":null,"spoken":"Hugo Example, 1900 to 1970. Your great-grandfather, Dad's side."},
 "header":null,"headerKind":"none",
 "nutshell":{"text":"Born in 1900. Kept the farm on Example Road and died there at 70.","spoken":"Born in 1900. Kept the farm on Example Road and died there at 70."},
 "livedThrough":"Born 1900; lived through World War I, the 1918 flu, the Depression and World War II.",
 "relation":{"term":"your great-grandfather","chain":"your dad's dad's dad","ladder":["You","Dad","Grandpa","His dad"],"pathPeople":[\##(jack),\##(ben),\##(dan),\##(hugo)],"pathText":"You, then your dad, then his dad Dan Example, then his dad Hugo Example.","dnaLine":"On average about 1 in 8 of your DNA comes from him. From the records, not a DNA test.","details":null},
 "pictures":{"total":0,"items":[]},
 "life":[{"year":1900,"text":"Born","spoken":"1900: born.","records":[]},{"year":1970,"text":"Died on Example Road, age 70","spoken":"1970: died on Example Road, age 70.","records":[]}],
 "family":{"parents":[\##(ivo)],"spouses":[],"siblings":[],"children":[\##(dan)]},
 "records":[],"grave":null,"findings":[],"sources":[],
 "withheld":{"count":1,"text":"1 source withheld: it names living relatives"},
 "share":{"allowed":true}}
"""##

    // MARK: GET /gallery, /media

    static let gallery = ##"""
{"kind":"photos","title":"Photos","total":2,"from":0,"count":2,
 "kinds":[{"key":"photos","title":"Photos","count":2},{"key":"records","title":"Records","count":1},{"key":"graves","title":"Graves","count":1},{"key":"all","title":"Everything","count":4}],
 "items":[
  {"id":"m-tree1r","category":"restored","w":640,"h":480,"year":1955,"thumb":null,"face":null,"short":"Photo restored with AI: your grandfather, Dan Example","alt":"Photo restored with AI: your grandfather, Dan Example, about 1955. A man in a work shirt on the steps of an invented porch.","described":"auto","hasText":false,"shareable":true,"restoredFrom":"m-tree1","restoredLabel":"Restored with AI: colours and repairs may be guessed","caption":"Dan Example on an invented porch (restored with AI)","people":[\##(dan)],"index":1},
  {"id":"m-tree1","category":"photo","w":640,"h":480,"year":1955,"thumb":null,"face":null,"short":"Photo: your grandfather, Dan Example","alt":"Photo: your grandfather, Dan Example, about 1955. A man in a work shirt on the steps of an invented porch.","described":"auto","hasText":false,"shareable":true,"restored":"m-tree1r","restoredLabel":"Restored with AI: colours and repairs may be guessed","caption":"Dan Example on an invented porch","people":[\##(dan)],"index":2}],
 "prev":null,"next":null,"pageSpoken":"Showing 1 to 2 of 2"}
"""##

    static let mediaInfo = ##"""
{"image":\##(photoDan),
 "caption":"Dan Example on an invented porch",
 "description":"A man in a work shirt stands on the steps of a wooden porch with one hand on the rail. Behind him a screen door is half open. Made up for the demo family.",
 "described":"auto","text":null,"textAuto":false,
 "people":[\##(dan)],
 "source":{"kind":"tree","title":"Family tree photo"}}
"""##

    static let signed = ##"""
{"urls":{},"expires":null}
"""##

    // MARK: GET /dna

    static let dna = ##"""
{"title":"Ada's DNA test counts for you too","follows":null,
 "test":{"applies":"fullSibling",
  "intro":"You and Ada have the same mother and father, so you have exactly the same ancestors. What her DNA test found about the family is true for you too. You each inherited different pieces, but they point to the same families.",
  "cards":[{"key":"c1","title":"The family of your grandfather Finn Sample","text":"3 of Ada's DNA cousins descend from this family.","people":[\##(finn),\##(gail)],"proof":"records","proofText":"Proven by records","storySlug":null,"spoken":"The family of your grandfather Finn Sample. 3 of Ada's DNA cousins descend from this family. Proven by records."}],
  "mysteries":{"headsUp":"This part is about who one of your ancestors' fathers was. It may be news to some of the family.",
   "cards":[{"key":"k1","title":"Who was Finn Sample's father?","text":"Finn's father is not named in any record. DNA points to a son of the Sample family who worked on an invented farm.","people":[\##(unknown),\##(finn)],"proof":"dna","proofText":"Strong DNA evidence (about 90–95% sure)","storySlug":null,"spoken":"Who was Finn Sample's father? Finn's father is not named in any record. DNA points to a son of the Sample family who worked on an invented farm. Research finding, strong DNA evidence, about 90 to 95 percent sure, not proven by records."}]},
  "details":{"title":"Details for DNA fans","rows":["DNA cousins sharing 20 cM or more were grouped by the families they descend from.","Made up for the demo family."]}},
 "paper":{"startGen":2,"note":"These are averages. Further back the real share varies a lot, and some ancestors pass down no DNA at all.",
  "generations":[
   {"gen":2,"name":"grandparents","slots":4,"named":4,"text":"All 4 of your grandparents have a name.","spoken":"Generation 2, grandparents: 4 of 4 known",
    "wedges":[
     {"ahnen":4,"state":"known","side":"father","person":\##(dan),"share":"1 in 4"},
     {"ahnen":5,"state":"known","side":"father","person":\##(eve),"share":"1 in 4"},
     {"ahnen":6,"state":"known","side":"mother","person":\##(finn),"share":"1 in 4"},
     {"ahnen":7,"state":"known","side":"mother","person":\##(gail),"share":"1 in 4"}]},
   {"gen":3,"name":"great-grandparents","slots":8,"named":2,"text":"2 of your 8 great-grandparents have a name.","spoken":"Generation 3, great-grandparents: 2 of 8 known",
    "wedges":[
     {"ahnen":8,"state":"known","side":"father","person":\##(hugo),"share":"1 in 8"},
     {"ahnen":9,"state":"unknown","side":"father","person":null,"share":"1 in 8"},
     {"ahnen":10,"state":"unknown","side":"father","person":null,"share":"1 in 8"},
     {"ahnen":11,"state":"unknown","side":"father","person":null,"share":"1 in 8"},
     {"ahnen":12,"state":"research","side":"mother","person":\##(unknown),"share":"1 in 8"},
     {"ahnen":13,"state":"unknown","side":"mother","person":null,"share":"1 in 8"},
     {"ahnen":14,"state":"unknown","side":"mother","person":null,"share":"1 in 8"},
     {"ahnen":15,"state":"unknown","side":"mother","person":null,"share":"1 in 8"}]}]},
 "birthplaces":{"gen":2,"title":"Where your 4 grandparents were born","rows":[{"place":"Invented County","count":3,"people":["@I300@","@I301@","@I302@"]}],"unknown":1,"note":"From birthplaces in records. This is not a DNA ethnicity estimate."},
 "abroad":{"text":"1 of your ancestors was born outside the United States.","rows":[{"person":\##(ivo),"text":"Your 2nd great-grandfather Ivo Example was born in Invented Land about 1870."}]},
 "compare":{"averages":[{"class":"first cousin","percent":"about 12.5%","details":"Made-up range for the demo family."},{"class":"grandparent","percent":"about 25%","details":null}]}}
"""##

    // MARK: GET /timeline

    static let timeline = ##"""
{"scope":"ancestors","follows":null,"lanes":4,"mapReady":true,
 "people":{"@I300@":\##(dan),"@I301@":\##(eve),"@I400@":\##(hugo),"@I500@":\##(ivo)},
 "decades":[
  {"decade":1950,"title":"1950s","summary":"4 of your ancestors were alive.","spoken":"1950s: 4 ancestors alive, 2 events","photo":\##(photoDan),
   "bars":[{"id":"@I300@","lane":0,"from":1930,"to":1999,"side":"father","research":false},{"id":"@I301@","lane":1,"from":1932,"to":2010,"side":"father","research":false},{"id":"@I400@","lane":2,"from":1900,"to":1970,"side":"father","research":false}],
   "context":[{"title":"The 1950 census","text":"3 of your ancestors were counted in the 1950 census.","spoken":"3 of your ancestors were counted in the 1950 census."}],
   "events":[{"year":1950,"text":"Dan Example was counted in the census in Invented County.","spoken":"1950: Dan Example was counted in the census in Invented County.","personId":"@I300@","research":false},{"year":1954,"text":"Dan Example married Eve Example.","spoken":"1954: Dan Example married Eve Example.","personId":"@I300@","research":false}]},
  {"decade":1900,"title":"1900s","summary":"2 of your ancestors were alive.","spoken":"1900s: 2 ancestors alive, 1 event","photo":null,
   "bars":[{"id":"@I400@","lane":2,"from":1900,"to":1970,"side":"father","research":false},{"id":"@I500@","lane":3,"from":1870,"to":1940,"side":"father","research":false}],
   "context":[],
   "events":[{"year":1900,"text":"Hugo Example was born.","spoken":"1900: Hugo Example was born.","personId":"@I400@","research":false}]},
  {"decade":1870,"title":"1870s","summary":"1 of your ancestors was alive.","spoken":"1870s: 1 ancestor alive, 1 event","photo":null,
   "bars":[{"id":"@I500@","lane":3,"from":1870,"to":1940,"side":"father","research":false}],
   "context":[],
   "events":[{"year":1870,"text":"Ivo Example was born in Invented Land.","spoken":"1870: Ivo Example was born in Invented Land.","personId":"@I500@","research":false}]}]}
"""##

    // MARK: GET /places

    static let places = ##"""
{"places":[
  {"id":"p1","short":"Invented County, IS","lat":44.261,"lon":-72.575,"precision":"county"},
  {"id":"p2","short":"Invented Land","lat":54.0,"lon":-2.0,"precision":"country"}],
 "people":{"@I300@":\##(dan),"@I400@":\##(hugo),"@I500@":\##(ivo)},
 "start":1950,
 "decades":[
  {"decade":1950,"title":"1950s","summary":"3 ancestors in 1 place","spoken":"1950s: 3 ancestors in 1 place.","counts":{"p1":3,"p2":0},"labels":["p1"],"moves":[],
   "list":[{"heading":"Invented State","rows":[{"placeId":"p1","text":"Invented County: 3 ancestors","people":["@I300@","@I301@","@I400@"]}]}]},
  {"decade":1890,"title":"1890s","summary":"1 ancestor in 1 place","spoken":"1890s: 1 ancestor in 1 place, 1 moved.","counts":{"p1":1,"p2":0},"labels":["p1"],
   "moves":[{"personId":"@I500@","from":"p2","to":"p1","year":1891}],
   "list":[{"heading":"Invented State","rows":[{"placeId":"p1","text":"Invented County: 1 ancestor","people":["@I500@"]}]}]}],
 "ocean":[{"personId":"@I500@","text":"Your 2nd great-grandfather came from Invented Land about 1891.","from":{"lat":54.0,"lon":-2.0,"name":"Invented Land"},"to":{"lat":44.261,"lon":-72.575,"name":"Invented County, IS"}}],
 "journeys":[{"personId":"@I500@","text":"Born in Invented Land in 1870, in Invented County by 1891."}],
 "unplaced":"2 ancestors have no place in the records yet."}
"""##

    // MARK: GET /stories, /story/the-farm

    static let stories = ##"""
{"stories":[{"slug":"the-farm","title":"The farm on Example Road","detail":"About 2 minutes","research":false}],
 "clippings":[{"id":"m-grave1","title":"Headstone","people":[\##(dan)]}]}
"""##

    static let story = ##"""
{"slug":"the-farm","title":"The farm on Example Road","detail":"About 2 minutes","research":null,
 "short":["Hugo Example kept a small farm on Example Road.","His son Dan grew up there and farmed it after him.","The farm was sold after Dan died in 1999."],
 "whoswho":[\##(hugo),\##(dan),\##(eve)],
 "blocks":[
  {"type":"h2","runs":[{"text":"The farm"}]},
  {"type":"p","runs":[{"text":"My great-grandfather Hugo kept a small farm on Example Road."},{"text":" ","em":false},{"text":"1","source":1}]},
  {"type":"p","runs":[{"text":"His son Dan grew up there, married Eve in 1954, and farmed it after him. "},{"text":"None of this is real.","em":true}]},
  {"type":"li","runs":[{"text":"Made up for the demo family."}]}],
 "sources":[{"n":1,"title":"1950 Invented Census"}],
 "chunks":[
  {"i":0,"text":"The farm. My great-grandfather Hugo kept a small farm on Example Road.","cues":[{"text":"The farm.","start":0.0,"end":0.13},{"text":"My great-grandfather Hugo kept a small farm on Example Road.","start":0.13,"end":1.0}]},
  {"i":1,"text":"His son Dan grew up there, married Eve in 1954, and farmed it after him. None of this is real.","cues":[{"text":"His son Dan grew up there, married Eve in 1954, and farmed it after him.","start":0.0,"end":0.77},{"text":"None of this is real.","start":0.77,"end":1.0}]}],
 "listen":true}
"""##

    // MARK: GET /findings, /findings?group=mysteries

    static let findings = ##"""
{"discoveries":[
  {"key":"f1","title":"Ben and Ned share a DNA match","text":"Your father and your uncle share an invented DNA match, which fits the family tree.","proof":"records","proofText":"Proven by records","people":[\##(ben),\##(ned)],"evidence":"Based on 2 sources: 1 census image and 1 grave.","storySlug":null,"dna":true,"spoken":"Ben and Ned share a DNA match. Your father and your uncle share an invented DNA match, which fits the family tree. Proven by records."}],
 "mysteries":{"title":"Family mysteries","headsUp":"This part is about who one of your ancestors' fathers was. It may be news to some of the family.","count":1}}
"""##

    static let mysteries = ##"""
{"headsUp":"This part is about who one of your ancestors' fathers was. It may be news to some of the family.",
 "findings":[
  {"key":"f2","title":"Who was Finn Sample's father?","text":"Finn's father is not named in any record. DNA points to a son of the Sample family who worked on an invented farm.","proof":"dna","proofText":"Strong DNA evidence (about 90–95% sure)","people":[\##(unknown),\##(finn)],"evidence":"Based on 3 sources: 2 census images and 1 newspaper page.","storySlug":null,"dna":true,"spoken":"Who was Finn Sample's father? Finn's father is not named in any record. DNA points to a son of the Sample family who worked on an invented farm. Research finding, strong DNA evidence, about 90 to 95 percent sure, not proven by records."}]}
"""##

    // MARK: GET /play

    static let play = ##"""
{"rounds":[
  {"kind":"relation","prompt":"Who is he to you?","spoken":"Who is Dan Example to you?","people":[\##(dan)],"image":null,
   "choices":[{"text":"your grandfather","spoken":"your grandfather"},{"text":"your uncle","spoken":"your uncle"},{"text":"your great-grandfather","spoken":"your great-grandfather"},{"text":"your mom's dad","spoken":"your mom's dad"}],
   "answer":0,"explain":"He's your grandfather: your dad's dad.","spokenExplain":"He's your grandfather: your dad's dad."},
  {"kind":"side","prompt":"Mom's side or Dad's side?","spoken":"Is Gail Sample on your mom's side or your dad's side?","people":[\##(gail)],"image":null,
   "choices":[{"text":"Mom's side","spoken":"Mom's side"},{"text":"Dad's side","spoken":"Dad's side"}],
   "answer":0,"explain":"Mom's side: she is your mom's mom.","spokenExplain":"Mom's side: she is your mom's mom."},
  {"kind":"older","prompt":"Who was born first?","spoken":"Who was born first, Hugo Example or Ivo Example?","people":[\##(hugo),\##(ivo)],"image":null,
   "choices":[{"text":"Hugo Example","spoken":"Hugo Example"},{"text":"Ivo Example","spoken":"Ivo Example"}],
   "answer":1,"explain":"Ivo, in 1870. Hugo was born in 1900.","spokenExplain":"Ivo, in 1870. Hugo was born in 1900."}]}
"""##

    // MARK: GET /people, /search

    static let people = ##"""
{"group":"ancestor","title":"Ancestors","total":8,"from":0,"count":8,"prev":null,"next":null,"pageSpoken":"Showing 1 to 8 of 8","spoken":"8 ancestors",
 "sections":[
  {"heading":"Parents","level":2,"rows":[{"id":"@I200@","spoken":"Your father, Ben Example, 1960 to 2020, Dad's side.","person":\##(ben)},{"id":"@I201@","spoken":"Your mother, Cora Example, born 1962, Mom's side.","person":\##(cora)}]},
  {"heading":"Grandparents","level":2,"rows":[{"id":"@I300@","spoken":"Your grandfather, Dan Example, 1930 to 1999, Dad's side.","person":\##(dan)},{"id":"@I301@","spoken":"Your grandmother, Eve Example, 1932 to 2010, Dad's side.","person":\##(eve)},{"id":"@I302@","spoken":"Your grandfather, Finn Sample, 1935 to 2001, Mom's side.","person":\##(finn)},{"id":"@I303@","spoken":"Your grandmother, Gail Sample, 1936 to 2015, Mom's side.","person":\##(gail)}]},
  {"heading":"Great-grandparents","level":2,"rows":[{"id":"@I400@","spoken":"Your great-grandfather, Hugo Example, 1900 to 1970, Dad's side.","person":\##(hugo)},{"id":"@I700@","spoken":"Your great-grandfather, name not known, identified by DNA as a son of the Sample family, Mom's side. Research finding.","person":\##(unknown)}]}],
 "people":[]}
"""##

    static let search = ##"""
{"total":1,"spoken":"1 person found",
 "sections":[],
 "people":[\##(dan)]}
"""##

    // MARK: POST /note

    static let noteSent = ##"""
{"ok":true,"text":"Sent to Ada. Thank you."}
"""##
}
#endif
