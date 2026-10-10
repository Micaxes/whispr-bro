import Foundation

/// The word lists `SelfRepair` reads, one per rule decision, named as in the
/// reference (`rules.py` v10) so the two can be read side by side
/// (docs/self-repair.md). Lower-case words compared by code point
/// (`ScalarString`). Every list is English — the stage never runs on another
/// dictation language — but the ones that name the words of other languages
/// an English dictation borrows: T3's doubles and `foreignWords` ("ciao
/// ciao", "tanti tanti", "caldo caldo"), which T23 reads too, and T20's
/// `r3aKeep` ("ti amo", "ve lo dico").
///
/// Two lists are not copies: the core fillers and the stutters FillerStripper
/// collapses are ITS sets, and the layout phrases are SpokenStructure's — so
/// the rules can never disagree with the stages they defer to.
enum SelfRepairLexicon {
    private static func words(_ text: String) -> Set<ScalarString> {
        Set(text.split(whereSeparator: \.isWhitespace).map { ScalarString(stringLiteral: String($0)) })
    }

    /// FillerStripper's filled pauses: repair evidence here, removed there.
    static let coreFillers = Set(FillerStripper.coreFillers.map { ScalarString(stringLiteral: $0) })

    static let numWords = words("""
        zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen
        fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty
        ninety hundred thousand million billion trillion
        """)
    static let ordinals = words("""
        first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth
        fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth twentieth thirtieth
        fortieth fiftieth sixtieth seventieth eightieth ninetieth hundredth thousandth
        """)
    static let units = words("""
        am pm percent k dollars dollar bucks euros cents minutes minute mins min seconds second secs
        sec hours hour hrs hr days day weeks week months month years year miles mile km kilometers
        kilometres meters metres feet foot ft pounds lbs kg kilos grams people users rows times
        """)

    static let weekdays = words("""
        monday tuesday wednesday thursday friday saturday sunday mondays tuesdays wednesdays
        thursdays fridays saturdays sundays
        """)
    static let months = words("january february march april june july august september october november december")
    static let daytime = words("today tomorrow tonight yesterday morning afternoon evening night noon midnight weekend")

    static let articles = words("a an the")
    static let demonstratives = words("this that these those")
    static let coordinators = words("and or but nor so yet then plus versus vs")
    static let prepositions = words("""
        about above across after against along among around at before behind below beneath beside
        between beyond by down during except for from in inside into near of off on onto out outside
        over past per since through throughout till to toward towards under until up upon via with
        within without
        """)
    static let auxiliaries = words("""
        am is are was were be been being do does did have has had will would shall should can could
        may might must ought isn't aren't wasn't weren't don't doesn't didn't haven't hasn't hadn't
        won't wouldn't shan't shouldn't can't cannot couldn't mightn't mustn't gonna wanna gotta
        """)
    static let pronouns = words("""
        i me my mine myself you your yours yourself yourselves he him his himself she her hers
        herself it its itself we us our ours ourselves they them their theirs themselves i'm i've
        i'll i'd you're you've you'll you'd he's he'll he'd she's she'll she'd it's it'll it'd we're
        we've we'll we'd they're they've they'll they'd that's there's here's let's
        """)
    static let determiners = words("""
        all any both each every either neither few many more most much no none some such other
        another own same several enough
        """)
    /// FUNC: closed-class words only (no discourse words such as actually /
    /// sorry / like).
    static let function: Set<ScalarString> = articles.union(demonstratives).union(coordinators)
        .union(prepositions).union(auxiliaries).union(pronouns).union(determiners)
        .union(words("""
            who whom whose which what whatever whoever where when why how if unless while
            whether than as because though although once not just also very too only
            """))

    // MARK: R1 — doubles that are not stutters

    /// Doubles that are ordinary English (grammar, emphasis, interjections).
    static let legitDoubles = words("""
        that had her very really too much many far long way more pretty super ever never no yes yeah
        yep yup nope bye ha haha hah ho hey hi hello oh ah aha ooh oo ow wow whoa well now there
        come hush tut tsk knock chop night boo yum dum la na da blah bla choo pooh hip hear please
        okay ok right sure good bang beep tick ding dong woo yay go run again in on old new big
        little tiny real done test testing mahi agar bora aye pom tom yo cha bon ylang baden walla
        sing pago hee haw hoo hu tra bom tum puss x xo
        """)
    /// T3: fixed doubles the first list missed ("win win", "cous cous"), and
    /// the Italian and Spanish ones an English dictation carries ("ciao ciao",
    /// "piano piano", "sì sì"); since v5 more of them, and the Portuguese,
    /// French, German, Arabic, Hindi, Greek and Hawaiian ones, kisses and
    /// sound words ("tanti tanti", "forza forza", "quasi quasi", "lomi lomi",
    /// "woof woof", "mwah mwah"). Each is a fixed or emphatic double in its
    /// language and none an everyday English word, so a stutter on it is rare;
    /// an everyday word ("wiki", "cool") stays out, and T18 keeps it only
    /// where the double stands alone. An accented word needs no entry: T3
    /// keeps the double of any word that is not ASCII.
    static let legitDoublesV2 = words("""
        win cous yada ciao piano pian si sì cosi così dai basta pronto bravo brava bene ecco grazie
        prego sí bueno vale así asi chao
        tanti tante tanto tanta baci bacio bacioni forza quasi via zitto zitta zitti subito presto
        andiamo bello bella bravi calma avanti vai sotto fermo ferma ancora molto poco guarda senti
        aspetta vieni corri terra pari passo auguri certo esatto allora daje piu gia
        claro vamos besos beso ya despacio dale andale rapido mira luego adios hola gracias venga chau
        muy casi oye ay
        tchau beijos beijo ja pois devagar quase nao
        oui non allez bisous merci tres ouais chut nein tschuss
        yalla shway shwaya jaldi chalo siga
        lomi huli lau kau holo muu
        woof meow moo baa oink quack honk putt vroom toot pow whoop nom heh shh mwah muah xie hai goody
        """)
    /// [T3] [T23] (v7) Everyday words of Italian (most of them), Spanish,
    /// Portuguese and French that English does not use: the adjectives and
    /// adverbs those languages double for emphasis ("caldo caldo", "lento
    /// lento", "lindo lindo"), the interjections, imperatives and endearments
    /// they double ("scusa scusa", "amore amore"), and the nouns of their "W a
    /// W" idioms ("faccia a faccia", "paso a paso", "dia a dia"). Every form
    /// spelt out; none is in Apple's English word embedding or written
    /// lower-case 5 times in 2.32M words of written English, so the English
    /// look-alikes stay off ("solo", "fine", "care", "petite", "gelato") — but
    /// for the Italian words English holds only as a borrowed term of music,
    /// art or a name ("piccolo", "dolce", "forte", "fresco", "alto").
    static let foreignWords = words("""
        buono buona buoni buone cattivo cattiva cattivi cattive brutto brutta brutti brutte piccola
        piccoli piccole piccolino piccolina grande grandi grosso grossa grossi grosse alta alti alte
        bassa basse lungo lunga lunghi lunghe corto corta corti corte larga larghi larghe stretto
        stretta stretti strette grasso grassa grassi grasse magro magra magri magre sottile sottili
        tonda tondi tonde dritto dritta dritti dritte storto storta storti storte pieno piena pieni
        piene vuoto vuota vuoti vuote pesante pesanti leggero leggera leggeri leggere duro dura duri
        dure morbido morbida morbidi morbide liscio liscia lisci lisce pulito pulita puliti pulite
        sporco sporca sporchi sporche nuovo nuova nuovi nuove vecchio vecchia vecchi vecchie giovane
        giovani fresca freschi fresche caldo calda caldi calde freddo fredda freddi fredde tiepido
        tiepida tiepidi bollente bollenti gelata gelati gelate bagnato bagnata bagnati bagnate asciutto
        asciutta asciutti asciutte dolci amaro amara amari amare salato salata salati salate piccante
        piccanti saporito saporita saporiti saporite lento lenta lenti lente veloce veloci svelto svelta
        svelti rapida rapidi rapide forti debole deboli facili difficile difficili semplice semplici
        chiaro chiara chiari chiare scuro scura scuri scure vicino vicina vicini vicine lontano lontana
        lontani lontane intero intera interi intere sola soli stanco stanca stanchi stanche contento
        contenta contenti contente felice felici triste tristi arrabbiato arrabbiata arrabbiati
        arrabbiate tranquillo tranquilla tranquilli tranquille calmo calmi calme carino carini carine
        simpatico simpatica simpatici simpatiche caro cara cari povero povera poveri povere ricco ricca
        ricchi ricche vero vera veri vere giusto giusta giusti giuste sbagliato sbagliata sbagliati
        sbagliate strano strana strani strane normale normali speciale speciali preciso precisa precisi
        perfetto perfetta perfetti perfette sicuro sicura sicuri sicure matto matta pazzo pazza pazzi
        pazze morto morta morti morte vivo viva vivi vive rosso rossa rossi rosse nero nera neri nere
        bianco bianca bianchi bianche verde verdi giallo gialla gialli gialle azzurro azzurra azzurri
        azzurre grigio grigia grigi grigie lucido lucida lucidi lucide fino fina fini tenero tenera
        teneri tenere gentile gentili elegante eleganti enorme enormi brevi pronta pronti pronte
        bellissimo bellissima bellissimi bellissime buonissimo buonissima buonissimi buonissime
        piccolissimo piccolissima caldissimo caldissima freddissimo freddissima stanchissimo
        stanchissima tantissimo tantissima tantissimi tantissime pochissimo moltissimo sempre mai troppo
        troppa troppi troppe davvero insieme dentro fuori sopra indietro appena adesso ora dopo prima
        tardi spesso almeno magari proprio abbastanza parecchio piuttosto veramente lentamente benissimo
        malissimo pianino scusa scusate attento attenta attenti attente aiuto dimmi boh uffa nonna nonno
        amore tesoro cucciolo cucciola bimba bimbi uno una mano faccia goccia corpo porta giorno casa
        palmo fianco spalla bocca cuore gomito croccante croccanti cremoso cremosa succosa cotto cotta
        cotti cotte crudo cruda crudi maturo matura maturi secca secchi secche umido umida umidi umide
        denso densa densi furbo furba furbi furbe goloso golosa golosi golose buffo buffa buffi buffe
        allegra allegri allegre piccolo dolce forte fresco alto basso bassi largo tondo breve allegro
        carina testa ahora ahorita mucho mucha muchos muchas poquito poquita malo mala malos malas
        bonito bonita bonitos bonitas lindo linda lindos lindas caliente calientes nuevo nueva nuevos
        nuevas viejo vieja viejos viejas chiquito chiquita chiquitos chiquitas cerca lejos temprano
        tarde tranquilo tranquila tranquilos tranquilas cansado cansada cansados cansadas feliz felices
        tristes rico ricos ricas sabroso sabrosa sabrosos sabrosas dulce dulces suaves fuerte fuertes
        limpio limpia limpios limpias sucio sucia sucios sucias lleno llena llenos llenas listo lista
        perfecta exacto cierto cierta seguro igual entero entera gorda flaco flaca bajo baja rojo roja
        blanco blanca azul amarillo amarilla corre ven anda porfa amor mas paso boca gota cuerpo puerta
        frente lado devagarinho devagarzinho rapidinho cedo perto longe bem muito muita muitos muitas
        pouco pouca poucos poucas gostoso gostosa quente quentes velho velha fofo fofa nossa obrigado
        obrigada saudade querido querida cheio cheia vazio vazia limpo limpa sujo suja pequeno pequena
        dia mais frio fria frios frias vacio vacia perdon despacito gordo cheri cherie vabbe doucement
        petits petites joli jolie jolis jolies bonne chaud chaude froid froide toute tous toutes trop
        doux douce gentil gentille mignon mignonne propre plein pleine coucou allons bises peu
        """)
    /// [T23] `legitDoublesV2`'s own English words and sounds: a head R2 may
    /// still restart ("Win a win the game"). The rest of that list is other
    /// languages', like `foreignWords`.
    static let legitDoublesV2English = words("""
        win cous yada woof meow moo baa oink quack honk putt vroom toot pow whoop nom heh shh mwah
        muah goody
        """)
    /// T19: copulas that are grammar after a wh-word, like `legitAfterWh`
    /// ("what they are are", "what he did did").
    static let whCopulas = words("are were did")
    /// T19: the verbs that take each particle — a phrasal verb's particle,
    /// then the same word as a preposition ("swing by by noon", "think it
    /// over over the weekend", "come around around 5", "write it down down
    /// the side").
    static let particleVerbs: [ScalarString: Set<ScalarString>] = [
        "by": words("""
            swing swings swung swinging stop stops stopped stopping drop drops dropped dropping come
            comes came coming pop pops popped popping go goes went gone going
            """),
        "over": words("""
            come comes came coming go goes went gone going head heads headed heading swing swings swung
            swinging pop pops popped popping sleep sleeps slept sleeping stay stays stayed staying stop
            stops stopped stopping fly flies flew flown flying drive drives drove driven driving bring
            brings brought bringing send sends sent sending invite invites invited inviting have has had
            having ask asks asked asking hop hops hopped hopping think thinks thought thinking talk talks
            talked talking mull mulls mulled mulling look looks looked looking hand hands handed handing
            pass passes passed passing
            """),
        "around": words("""
            come comes came coming swing swings swung swinging stop stops stopped stopping drop drops
            dropped dropping head heads headed heading
            """),
        "down": words("write writes wrote written writing jot jots jotted jotting note notes noted noting"),
    ]
    /// T19: what makes the phrase after the double a time ("by noon", "over
    /// the holidays", "by the end of the day", "over lunch").
    static let timeNouns = words("""
        end start beginning weekend weekends week weeks month months year years day days hour hours
        minute minutes holiday holidays break summer winter autumn lunch dinner breakfast brunch
        lunchtime coffee drinks then christmas thanksgiving easter
        """)
    static let timeModifiers = words("whole entire next last first following coming same long early late")
    static let timeDeterminers = words("next last")
    /// "by the end of the day" is a time; "two weeks of data" is not.
    static let timeOf = words("end start beginning middle")
    /// T19: a number after "by" or "around" is a time only as a clock time
    /// ("by 5 if you can"); after "over" it is an amount ("over 50 files").
    static let clockParticles = words("by around")
    static let hours = words("1 2 3 4 5 6 7 8 9 10 11 12 one two three four five six seven eight nine ten eleven twelve")
    static let clockWords = words("am pm o'clock oclock")
    /// "by 5 each year" is an amount.
    static let amountFunction = words("each every per a an more most of")
    /// T4: spoken symbol names, said twice on purpose ("dash dash verbose",
    /// "C plus plus", "hit tab tab").
    static let symbolWords = words("""
        dash hyphen slash backslash star asterisk colon semicolon quote backtick underscore dot
        period comma equals plus minus pipe ampersand hash tilde caret dollar percent tab escape esc
        enter backspace
        """)
    static let symbolPhrases: Set<[ScalarString]> = [["greater", "than"], ["less", "than"]]
    /// T4: SpokenStructure's marker phrases as R1 units — it drops a
    /// redundant "new line new line" itself. (With T16 on, a marker never
    /// reaches a rule at all.)
    static let spokenMarkers: Set<[ScalarString]> = Set(spokenPhrases.map(\.words))
    /// T16: SpokenStructure's marker phrases in ITS order (longest first), so
    /// the rules find exactly the phrases it will lift out, and what each one
    /// marks: the end of a line ("new line"), a list item ("bullet point":
    /// T18 reads what follows it as an item), or the opening or closing of a
    /// spoken quotation (T17 reads the words between a pair as a mention).
    /// Read from `SpokenStructure.phrases`, so the two can never drift.
    static let spokenPhrases: [(words: [ScalarString], kind: SelfRepair.Marker)] = SpokenStructure.phrases.map { phrase in
        let kind: SelfRepair.Marker
        switch phrase.kind {
        case .quoteOpen: kind = .quoteOpen
        case .quoteClose: kind = .quoteClose
        case .bullet: kind = .bullet
        default: kind = .lineBreak
        }
        return (phrase.words.map { ScalarString(stringLiteral: $0) }, kind)
    }

    // MARK: T17 — a mention of words is not a repair (the reference's MENTIONS)

    /// Verbs whose object can be words: saying, dictating, typing, writing,
    /// transcribing, reading, hearing, printing, pasting, inserting, showing.
    static let reportVerbs = words("""
        say says said saying dictate dictates dictated dictating type types typed typing write writes
        wrote written writing transcribe transcribes transcribed transcribing read reads reading hear
        hears heard hearing print prints printed printing paste pastes pasted pasting insert inserts
        inserted inserting show shows showed shown showing display displays displayed displaying
        """)
    /// The expectation verbs that take words ("it should return <m>").
    static let expectVerbs = words("return returns returned returning output outputs outputted expect expects expected expecting")
    /// …whose number or object pronoun is a quantity or a thing ("we expected
    /// 30, sorry, 40 guests", "it printed 30 pages", "I expected you at 6").
    static let valueVerbs = expectVerbs.union(words("""
        hear hears heard hearing print prints printed printing paste pastes pasted pasting insert
        inserts inserted inserting show shows showed shown showing display displays displayed displaying
        """))
    /// An imperative's form ("Say thanks" opens nothing).
    static let baseVerbs = words("say type write dictate transcribe read return output expect hear print paste insert show display")
    /// "expect" with a clause predicts events: "I expect we'll land at 6,
    /// sorry, 7" is his correction.
    static let predictVerbs = words("expect expects expected expecting")
    static let clauseOpeners = words("""
        i you we they he she it i'm you're we're they're he's she's it's i'll you'll we'll they'll
        he'll she'll it'll i'd you'd we'd they'd he'd she'd that there
        """)
    /// "wrote back", "heard back": the verb takes no words.
    static let particles = words("back")
    /// An embedded question reports content, not wording ("a flag that prints
    /// what would change").
    static let whObject = words("what how which whether why when where who whom whose whatever however")
    /// Their object is always words, even in an imperative.
    static let wordsVerbs = words("dictate dictates dictated dictating transcribe transcribes transcribed transcribing")
    /// A reading from an instrument is not speech: "my watch says 48, sorry,
    /// 49" is his correction.
    static let sayRead = words("""
        say says said saying read reads reading show shows showed shown showing display displays
        displayed displaying
        """)
    static let subjectPronouns = words("""
        someone somebody everyone everybody anyone anybody nobody whoever i you we they he she it who
        which that i'm you're we're they're he's she's it's i'll you'll we'll they'll he'll she'll
        it'll i've you've we've they've
        """)
    /// "I'd say", "let's say", "to say": a hedge, not a quotation.
    static let hedges = words("i'd you'd we'd they'd he'd she'd would could might let's lets to gonna wanna gotta")
    /// "it should say <m>".
    static let reportModals = words("should must will can shall may does did do")
    static let reportAdverbs = words("""
        just also only even literally actually accidentally always never once first then simply
        originally initially basically clearly still really already
        """)
    /// "was saying", "keep saying".
    static let reportChain = words("am is are was were be been being keep keeps kept start starts started try tries tried")
    static let notSubject = words("please go let kindly now")
    static let npOpeners = articles.union(demonstratives).union(possessives).union(words("every each some any no"))
    static let instruments = words("""
        watch watches clock clocks scale scales thermometer gauge meter meters speedometer odometer
        tracker monitor sensor readout display dial compass altimeter timer stopwatch calculator garmin
        whoop strava fitbit oura chart graph dashboard stats forecast gps
        """)
    /// "I expected you at 6": not words.
    static let objectPronouns = words("me you him her us them it")
    /// Framing nouns: "a test where <m>", "the input is <m>", "the phrase <m>".
    static let frameNouns = words("""
        phrase phrases sentence sentences example examples input inputs output outputs test tests
        fixture fixtures case cases string strings text texts prompt prompts transcript transcripts
        command commands message messages word words sample samples snippet snippets utterance
        utterances dictation dictations quote quotes
        """)
    static let repairNouns = words("""
        correction corrections repair repairs restart restarts stutter stutters repeat repeats
        repetition repetitions fragment fragments swap swaps retraction retractions
        """)
    static let expectedNouns = frameNouns.union(words("result results value values answer outcome behavior behaviour"))
    /// Never scheduled: "the phrase <m>".
    static let apposNouns = words("""
        phrase phrases sentence sentences string strings word words example examples sample samples
        snippet snippets utterance utterances
        """)
    static let copulaNouns = words("""
        input inputs output outputs transcript transcripts prompt prompts command commands string
        strings phrase phrases text texts message messages example examples sentence sentences word
        words utterance utterances snippet snippets dictation dictations quote quotes
        """)
    /// A number after "is" is still words.
    static let specimenNouns = words("example examples snippet snippets")
    static let frameLinkers = words("where like with for")
    static let ofNouns = words("example examples sample samples case cases")
    static let copulas = words("is was are were becomes reads stays stayed remains remained")
    /// "the output should be / stay / remain <m>".
    static let beLinks = words("be stay remain")
    /// A text noun's containing verb takes its words, unless they are a thing.
    static let containVerbs = words("has have had contains contain contained includes include included")
    /// A copula's complement that grades the noun is content ("the prompt is
    /// too long"); "still", "now", "just" can introduce words.
    static let degree = words("too very so quite pretty really rather not")
    static let beModals = words("should must will would could might can")
    /// "<m> is a stutter", "<m> as a weekday swap".
    static let naming = words("is was are were as")
    static let clausey = pronouns.union(articles).union(demonstratives).union(determiners)
    static let npStart = articles.union(possessives).union(demonstratives).union(determiners)
    static let temporal = weekdays.union(months).union(daytime)
    /// A label before a colon: "Expected: <m>", "Before: <m> After: <m>".
    static let colonLabels = words("expected actual got result results raw before after original gold")
    /// "she wrote back: <m>", "he told me: <m>".
    static let colonReport = reportVerbs.union(words("""
        tell tells told ask asks asked reply replies replied answer answers answered text texts texted
        message messages messaged email emails emailed post posts posted comment comments commented
        note notes noted
        """))
    /// "for example <m>", "such as <m>", "like when <m>", "e.g. <m>".
    static let exemplifiers: [[ScalarString]] = [
        ["for", "example"], ["for", "instance"], ["such", "as"], ["like", "when"], ["e.g"], ["eg"], ["i.e"], ["ie"],
    ]
    /// "turn <m> into <m>", "change <m> to <m>", …: each verb and the words
    /// that link its two sides. Every one needs the second side to read as the
    /// first with words taken out.
    static let rewriteLinks: [ScalarString: Set<ScalarString>] = {
        let table: [(String, String)] = [
            ("turn turns turned turning", "into"),
            ("change changes changed changing", "to into"),
            ("convert converts converted converting", "to into"),
            ("rewrite rewrites rewrote rewritten rewriting", "as to into"),
            ("replace replaces replaced replacing", "with by"),
            ("resolve resolves resolved resolving", "to into"),
            ("collapse collapses collapsed collapsing", "to into"),
            ("reduce reduces reduced reducing", "to"),
            ("normalize normalizes normalized normalizing normalise normalises normalised normalising", "to into"),
            ("shorten shortens shortened shortening", "to"),
            ("simplify simplifies simplified simplifying", "to into"),
            ("correct corrects corrected correcting", "to into"),
            ("map maps mapped mapping", "to onto"),
        ]
        var out: [ScalarString: Set<ScalarString>] = [:]
        for (verbs, links) in table { for verb in words(verbs) { out[verb] = words(links) } }
        return out
    }()
    /// A rewrite frame after the words, tried in order: "<m> becomes <m>",
    /// "<m> comes out as <m>", "<m> is changed to <m>", …
    static let postfixFrames: [[Set<ScalarString>]] = [
        [words("become becomes became becoming")],
        [words("turn turns turned turning"), words("into")],
        [words("come comes came coming"), words("out back"), words("as")],
        [words("end ends ended ending"), words("up"), words("as")],
        [words("clean cleans cleaned cleaning"), words("up"), words("to into as")],
        [words("changed converted cleaned"), words("to into")],
        [words("rewritten"), words("as to into")],
        [words("replaced"), words("with by")],
        [words("""
            resolve resolves resolved collapse collapses collapsed normalize normalizes normalized
            normalise normalises normalised simplify simplifies simplified
            """), words("to into")],
        [words("reduce reduces reduced shorten shortens shortened corrected"), words("to")],
    ]
    /// "should become", "is changed to": stepped back over before the words.
    static let frameAux = words("should must will would can could to is was gets got be been being does did do")
    /// Literal fidelity right after the words: "keep <m> verbatim", "<m>
    /// stays as is".
    static let verbatim: [[ScalarString]] = [
        ["verbatim"], ["unchanged"], ["untouched"], ["intact"], ["as", "is"], ["as-is"], ["word", "for", "word"],
        ["as", "dictated"], ["as", "said"], ["as", "spoken"], ["as", "written"], ["as", "typed"],
    ]
    /// A deletion described on the text: "it deleted Thursday from Thursday,
    /// no wait, Friday".
    static let editVerbs = words("""
        delete deletes deleted deleting remove removes removed removing drop drops dropped dropping cut
        cuts cutting strip strips stripped stripping erase erases erased erasing lose loses lost losing
        """)
    static let editLinks = words("from in of")
    /// Words put into a test artifact are test data: "use <m> as the probe",
    /// "add <m> to the keep list test".
    static let specLinks = words("as to in into")
    static let placeVerbs = words("""
        add adds added adding use uses used using include includes included including put puts putting
        paste pastes pasted pasting insert inserts inserted inserting append appends appended appending
        """)
    static let specNouns = words("""
        test tests fixture fixtures probe probes suite suites case cases input inputs example examples
        sample samples benchmark benchmarks eval evals regression regressions
        """)
    /// A mention reaches this many view tokens forward, to the end of its
    /// clause if that comes first…
    static let mentionReach = 12
    /// …and back, from a rewrite frame, a repair's name or a fidelity mark.
    static let mentionReachBack = 12
    /// T1: a modal or do-auxiliary that inverts a question ("Does the fix fix …").
    static let questionAuxiliaries = words("""
        do does did can could will would shall should may might must don't doesn't didn't can't
        cannot couldn't won't wouldn't shan't shouldn't mightn't mustn't
        """)
    static let t1Determiners = words("a an the this that these those my your our their his her its")
    /// T2b: a capitalised sentence opener that is a name AND, right after a
    /// name, a verb form spelled the same: past tenses ("Drew drew") and
    /// modals ("Will will").
    static let namePast = words("drew rose")
    static let nameModal = words("will may")
    /// T6: emphatic "do do" follows its subject: one of these, or a content word.
    static let doSubjects = words("i you we they who that which")
    /// T11a: letters whose spoken name starts with a vowel sound take "an".
    static let anLetters = words("f h l m n r s x")
    /// T11b: unit abbreviations written after a number ("a 10 k run", "5 mi").
    static let unitAbbreviations = words("""
        k m mi km kg g mg ml l lb lbs oz ft hr hrs h min mins sec secs s ms gb mb tb kb x
        """)
    /// T5: elisions written with a leading apostrophe; they open no quotation.
    static let elisions = words("cause em til n round bout kay twas tis s d ll re ve m t")
    /// T5: a single-quoted span closes within this many tokens of its opener.
    static let quoteWindow = 12
    /// Doubles that are grammar only after a wh-word ("what it is is").
    static let legitAfterWh = words("is was do does")
    static let whWords = words("what where how why who whatever whoever")
    /// The stutters FillerStripper already collapses when doubled with only
    /// spaces between (`stutterCollapsible`): left to it.
    static let fillerStripperCollapsible = Set(FillerStripper.stutterCollapsible.map { ScalarString(stringLiteral: $0) })
    /// R1/R2: a comma after these never closes a clause, so "X, X" is a stutter.
    static let commaOK = words("a an the my your our their its i we they he she and but or if because")
    static let softInterregnumOK = words("a an the my your our their to of for with in on at and")

    // MARK: R1B, R2, R2B

    static let pluralTriggers = words("""
        these those many several few multiple various both two three four five six seven eight nine
        ten eleven twelve fifteen twenty thirty forty fifty hundred dozens hundreds thousands
        """)
    static let r2FunctionHeads = words("and or but to of in on for with at from into")
    /// Discourse words never head a restart.
    static let r2HeadBlock = words("like well okay ok yeah so just really actually")
    /// R2, a one-word content head opening a sentence: B may be one of these.
    static let r2InitialB = words("a an the my your our their its this that these those one some any i you he she we they it")
    /// "the tickets go that go stale": the restart keeps B.
    static let r2KeepB = words("that which who")
    static let r2bNext = words("it we they he she it's we're they're he's she's")

    // MARK: R3 — fragments

    static let shortWords = words("""
        a i o am an as at be by do go he hi if in is it me my no of oh ok on or so to up us we ah aw
        eh ha hm mm ow uh um ya ye yo ad ai ax ex id ma pa ox tv pc os ui ux ip qa hq vs ie eg pm km
        kg mb gb kb ms cm ml ft lb oz hr st nd rd th db js ts py md ci cd vm io uk eu la ny sf dc tx
        ca mr dr jr sr et al ls rm mv cp vi sh gh ay du ed em en im lo mi sq wi yd de le te di da ne
        ni na il el se si au ce va tu ou un ho
        """)
    /// [T20] (v6) Short words R3a took for non-words although they are words:
    /// of Italian, Spanish, French, German, Portuguese and Hawaiian ("ti amo",
    /// "fa freddo", "chi sa", "un po", "je ne sais") and of English ("kung
    /// fu", "deja vu", "a photo op", "pi", "an ab workout"); (v7) "ve lo
    /// dico", "j'ai lu", "eu ri", "vamos ir", "wo bist du", English "fi" ("wi
    /// fi", "lo fi"), and the "ve" of a split "we ve". (v8) Every one- and
    /// two-letter string the macOS spelling checkers of Italian, Spanish,
    /// French, Portuguese and German accept that is a word of its language:
    /// v7 still took the interjections and verb forms "ia", "uy", "ea", "ey",
    /// "ih", "hu", "ji", "jo", "ju", "ra", "ro", "ut", "ar", "cu", "ki", "oc"
    /// ("eu ia te ligar"). What those checkers also accept that is no word —
    /// letters and their names, abbreviations and symbols, Roman numerals,
    /// chat shorthand ("gr", "pr", "pq") — stays R3a's, as does "fo", far
    /// likelier a cut-off "for". R3a only: T10 and R2 keep `shortWords`.
    static let r3aKeep = words("""
        ti su fa sa li po mo fu es je qu ta vu ja zu ab ao ka ke
        pi op ew oy oi om ag bi mu nu xi
        ve od vo ir ri fe uf lu bu pu ob wo ei fi
        ar cu ea ey hu ia ih ji jo ju ki oc ra ro ut uy
        """)
    /// R3b: real short words that may precede a word they prefix ("my ex explained").
    static let r3bKeep = words("ok go hi ex ad id ai tv pc os ui ux uk eu ya ye yo oh ah eh ha hm mm ow aw ma pa ax ox la")
    /// R3a: a lone letter naming something ("the s flag", "plan b").
    static let letterNouns = words("""
        flag flags key keys option options axis value values variable variables param parameter
        column row drive grade tier plan type size mode button command switch register train line
        team vitamin section block field shift string version model file note chord major minor
        sharp flat word letter
        """)
    static let letterBefore = words("plan option vitamin type grade section version model letter press hit key")
    static let prefixSplits = words("re un co de bi tri mis non sub pre anti semi multi mid ex")
    static let r3SkipLetters = words("a i o x y z e k t u v n")
    /// R3b: common 3-letter words, never a fragment — every lower-case
    /// 3-letter word seen 10+ times in 2.0M words of public English
    /// (Gutenberg + WikiText-2), plus everyday and dev-talk words.
    static let common3 = words("""
        act add aft age ago aid aim air all and any api app apt arc are arm art ash ask ass ate awe
        aws axe aye bad bag ban bar bat bay bed beg bet bid big bit bow box boy bug bus but buy bye
        cab can cap car cat cli cpu cry css cup cut dad dam dat day den dev dew did die dig dim dns
        dog don dry due dug ear eat egg end era ere err etc eve eye fan far fat fed fee few fin fit
        fix fly foe fog for fro fun fur gap gas gay get gin git giv god got gpu gun guy had has hat
        hay hem her hey hid him his hit hot how hue hug hum hut ice icy ill ink inn ios its ivy jam
        jar jaw jet job joy kep key kid lab lad lap law lay led lee leg let lid lie lip lit log loo
        lot low mac mad man map mat may men met mid mix mob mom mph mud mug nap nay net new nod nor
        not now npm oak oar odd off oil old one our out owe owl own pad pan pay pen per pet php pie
        pig pin pit pop pot put rag ram ran rap rat raw ray red rib rid rim rob rod row rub rug rum
        run sad sat saw say sdk sea see set sex she shy sin sip sir sit six ski sky sly sob son spy
        sql ssd sum sun tag tan tap tar tax tea ten the thy tie tin tip tis ton too top tow toy try
        tub two url usb use van vet via von vow war was wax way web wet who why wig win wit woe won
        wos wot yer yes yet you zip zoo
        """)

    // MARK: R4, R4S, R5 — cued corrections

    /// Tried in this order; the first whose words match wins.
    static let cues: [[ScalarString]] = [
        ["i", "mean"], ["i", "meant"], ["no", "wait"], ["scratch", "that"], ["or", "rather"], ["sorry"],
        ["actually"], ["no"], ["wait"],
    ]
    static let sentenceCues: [[ScalarString]] = [
        ["scratch", "that"], ["actually"], ["no", "wait"], ["no"], ["sorry"], ["i", "mean"], ["wait"],
    ]
    static let strongCues: Set<[ScalarString]> = [
        ["i", "mean"], ["i", "meant"], ["or", "rather"], ["no", "wait"], ["scratch", "that"],
    ]
    static let iMeanBlockBefore = words("what that not do don't didn't you always really never")
    /// [T21] (v6) A subject pronoun that opens a clause after a mid-sentence
    /// "scratch that" ("…, scratch that, I'll drive").
    static let subjectWords = words("i you he she it we they")
    /// [T21] What opens the noun phrase a bare noun phrase after "scratch
    /// that" replaces, and the predeterminer that may stand before it ("all
    /// the engineers").
    static let npDeterminers = articles.union(demonstratives).union(possessives).union(determiners)
    static let predeterminers = words("all both half")
    /// [T24] (v8) What makes the word after a cue the head of a verb phrase:
    /// an object right after it — a determiner, a possessive or an object
    /// pronoun ("fork the branch", "clone it") — unless an article or a
    /// demonstrative opens a time ("salad this time", "the weekend"); and
    /// what opens the noun phrase X_last heads ("the branch", "in cold
    /// storage" — not "to", mostly the infinitive's).
    static let verbPhraseObjects = words("the a an my your our their his her its it them this these those him me us")
    static let timeOpeners = articles.union(demonstratives)
    static let timeWords = temporal.union(timeNouns).union(words("time times"))
    static let nounPhraseHeadOpeners = npDeterminers.union(prepositions.subtracting(words("to")))
    /// [T24] (v9) The object pronouns that are no determiner: no noun takes
    /// one right after it ("delete it", "back them up"; "her" is a possessive
    /// too: "director her question").
    static let objectPronounsStrict = words("it them him me us")
    /// [T24] (v10) "her" is the object pronoun, not a possessive, where no
    /// noun can follow it: at a break or the end, or before one of these
    /// ("text her", "call her tonight"; not "director her question").
    static let herAfter = words("today tonight tomorrow yesterday later now soon again")
    /// [T24] (v10) The one particle that may stand right after the Y-side
    /// word before X_last said again as its object: these make it the object
    /// ("clear out the cache"); in / on / off / over are a particle or a
    /// preposition ("hand in the forms" reads like "the lock on the door"),
    /// so X said again after one of them is ambiguous.
    static let restateParticles = words("out up down back away")
    static let ambiguousParticles = words("in on off over")
    /// [T26] (v9) What stands before the verb of X's verb phrase and stays
    /// when "scratch that" takes the verb phrase back: an auxiliary or modal,
    /// a coordinator, the infinitive "to", "please" (in code also a
    /// contracted pronoun, and a subject pronoun after an auxiliary or a
    /// coordinator: "can you email", "and she texted").
    static let verbPhraseLeadIns = auxiliaries.union(coordinators).union(words("to please"))
    /// [T26] (v10) The words that open a relative clause ("the guy who can
    /// fix it"), also contracted ("who'll"); the second list opens one only
    /// right after a noun ("the room that we can use", "the room where we
    /// can meet").
    static let relativeWords = words("who whom whose which")
    static let nounRelativeWords = words("that where when")
    /// [T26] (v11) "when" opens a relative clause only right after an
    /// article and one of these ("a time when we can meet"); after any other
    /// word it opens an adverbial clause ("call the client when you can
    /// review it", "ping me tomorrow when you can").
    static let relativeTimeHeads = words("""
        day days time times week weeks month months year years moment moments date dates hour hours
        night nights weekend weekends
        """)
    /// [T24] (v11 for T25; v12 for T24) A possessor that takes no determiner
    /// of its own — besides a capitalised word (a name, "Monday's") — a
    /// pronoun-like or time word, or a family word used as a name. (v12) A
    /// word tagged Noun right before a possessive in lower case that is not
    /// one of these is that possessive's own modifier ("head chef's notes"),
    /// no verb before its object ("email everyone's notes" still is one).
    static let possessorsWithoutDeterminer = words("""
        everyone's everybody's someone's somebody's anyone's anybody's nobody's today's tonight's
        tomorrow's yesterday's mom's dad's mum's mommy's daddy's mama's papa's grandma's grandpa's
        granny's nana's
        """)
    /// [T24] (v12) Common irregular past forms. With a form in -ed or -s, one
    /// of these right after the word after the cue makes the two a subject
    /// and its verb ("Sam paid the invoice"), not a two-word verb ("power
    /// wash the deck").
    static let irregularPast = words("""
        paid sent sold made took gave brought bought told wrote drove ran ate met kept left found got sat
        stood spent lent lost won built caught taught thought held hung led shot slept swam threw woke wore
        broke chose froze spoke stole forgot went came became began drank rang sang sank flew grew knew drew
        blew
        """)
    /// (v13) v11's own lists, read only by the shadow run of v11's rules
    /// (`SelfRepair.cued11`): the determiners v11's possessive took the place
    /// of, and the verbs that take two objects, before which v11 kept a
    /// possessive said with the head again both ways ("Give the dog treats").
    static let possessiveReplaces = articles.union(demonstratives).union(possessives)
        .union(words("another any each every either neither"))
    static let twoObjectVerbs = words("""
        give gives gave giving send sends sent sending show shows showed showing hand hands handed
        handing bring brings brought bringing buy buys bought buying get gets got getting pass passes
        passed passing offer offers offered offering email emails emailed emailing text texts texted
        texting mail mails mailed mailing pay pays paid paying lend lends lent lending owe owes owed
        owing teach teaches taught teaching sell sells sold selling make makes made making cook cooks
        cooked cooking order orders ordered ordering book books booked booking save saves saved saving
        forward forwards forwarded forwarding ship ships shipped shipping serve serves served serving
        feed feeds fed feeding grab grabs grabbed grabbing fetch fetches fetched fetching leave leaves
        left leaving
        """)
    /// [T25] (v11) What makes the phrase after the cue an addition, not a
    /// correction: its last word one of these, its last two "as well", or
    /// "also" anywhere in it ("Sam's folder works too").
    static let additionLast = words("too either")
    static let iMeanBlockAfter = words("it to that business what well")
    /// NLTagger lexical classes that make two words the same kind of slot.
    static let openClasses: Set<String> = ["Noun", "Verb", "Adjective", "Adverb"]
    static let colors = words("red orange yellow green blue purple pink brown black white gray grey gold silver")
    static let directions = words("""
        left right top bottom front back north south east west upper lower inner outer inside
        outside
        """)
    static let frequency = words("daily weekly monthly yearly hourly nightly annually quarterly biweekly")
    static let ingStop = words("""
        nothing something anything everything thing things king ring sing bring spring string wing
        sling during ceiling building morning evening
        """)
    static let cueWords = words("i mean meant no wait sorry scratch that or rather actually")
    static let possessives = words("my your our their his her its")
    /// R4 rule 3: X_last must sit in a noun/prepositional phrase (after one of these).
    static let slotOpeners = articles.union(demonstratives).union(prepositions).union(possessives).union(determiners)
    /// R2 (head of 2+ tokens): the abandoned remainder is made of these and ends unfinished.
    static let possessiveDeterminers = words("my your our their its")
    static let r2BInner = pronouns.union(articles).union(possessiveDeterminers).union(words("to"))
    static let r2BLast = articles.union(possessiveDeterminers).union(words("to"))

    // MARK: Punctuation

    /// A token whose lead holds one of these opens a clause (" “ ‘ ( [ { — – -).
    static let openBreak: Set<Unicode.Scalar> = ["\"", "\u{201C}", "\u{2018}", "(", "[", "{", "\u{2014}", "\u{2013}", "-"]
    /// A token whose trail holds one of these ends a clause hard.
    static let hardTrail: Set<Unicode.Scalar> = [".", "?", "!", ";", ":", "\u{2026}", ")", "]", "}", "\"",
                                                 "\u{201D}", "\u{2019}", "\u{2014}", "\u{2013}"]
    /// T15: the hard trail characters that end a sentence or clause.
    static let sentenceTrail: Set<Unicode.Scalar> = [".", "?", "!", ";", ":", "\u{2026}"]
}
