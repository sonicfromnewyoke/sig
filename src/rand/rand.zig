const std = @import("std");
const sig = @import("../lib.zig");
const chacha = @import("chacha.zig");

const Allocator = std.mem.Allocator;
const Random = std.Random;

pub const ChaCha = chacha.ChaCha;
pub const ChaChaRng = chacha.ChaChaRng;

/// Uniformly samples a collection of weighted items. This struct only deals with
/// the weights, and it tells you which index it selects.
///
/// This deterministically selects the same sequence of items as WeightedIndex
/// from the rust crate rand_chacha, assuming you use a compatible pseudo-random
/// number generator.
///
/// Each index's probability of being selected is the ratio of its weight to the
/// sum of all weights.
///
/// For example, for the weights [1, 3, 2], the probability of `sample` returning
/// each index is:
/// 0. -> 1/6
/// 1. -> 1/2
/// 3. -> 1/3
pub fn WeightedRandomSampler(comptime uint: type) type {
    return struct {
        allocator: Allocator,
        random: Random,
        cumulative_weights: []const uint,
        total: uint,

        const Self = @This();

        pub fn init(
            allocator: Allocator,
            random: Random,
            weights: []const uint,
        ) Allocator.Error!Self {
            var cumulative_weights: []uint = try allocator.alloc(uint, weights.len);
            var total: uint = 0;
            for (0..weights.len) |i| {
                total += weights[i];
                cumulative_weights[i] = total;
            }
            return .{
                .allocator = allocator,
                .random = random,
                .cumulative_weights = cumulative_weights,
                .total = total,
            };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.cumulative_weights);
        }

        /// Returns the index of the selected item
        pub fn sample(self: *const Self) uint {
            const want = uintLessThanRust(self.random, uint, self.total);
            var lower: usize = 0;
            var upper: usize = self.cumulative_weights.len - 1;
            var guess = upper / 2;
            for (0..self.cumulative_weights.len) |_| {
                if (self.cumulative_weights[guess] >= want) {
                    upper = guess;
                } else {
                    lower = guess + 1;
                }
                if (upper == lower) {
                    return upper;
                }
                guess = lower + (upper - lower) / 2;
            }
            unreachable;
        }
    };
}

/// Wrapper for random number generators which generate blocks of [64]u32.
/// Minimizes calls to the underlying random number generator by recycling unused
/// data from previous calls. Port of BlockRng from rust which ensures the same
/// sequence is generated.
pub fn BlockRng(
    comptime T: type,
    comptime generate: fn (*T, *[64]u32) void,
) type {
    return struct {
        results: [64]u32 = undefined,
        index: usize = 64,
        core: T,

        const Self = @This();

        pub fn random(self: *Self) Random {
            return Random.init(self, fill);
        }

        pub fn fill(self: *Self, dest: []u8) void {
            var completed_bytes: usize = 0;
            while (completed_bytes < dest.len) {
                if (self.index >= self.results.len) {
                    generate(&self.core, &self.results);
                    self.index = 0;
                }
                const src: [*]u8 = @ptrCast(self.results[self.index..].ptr);
                const num_u8s = @min(4 * (64 - self.index), dest.len - completed_bytes);
                @memcpy(dest[completed_bytes..][0..num_u8s], src[0..num_u8s]);

                self.index += (num_u8s + 3) / 4;
                completed_bytes += num_u8s;
            }
        }
    };
}

pub fn errorValue(rand: std.Random, comptime ErrorSet: type) ?if (ErrorSet == anyerror) noreturn else ErrorSet {
    if (ErrorSet == anyerror) return null;
    return switch (rand.enumValue(std.meta.FieldEnum(ErrorSet))) {
        inline else => |itag| @field(ErrorSet, @tagName(itag)),
    };
}

/// Empties the provided hashmap, and then fills it with `hm_len` entries,
/// each with a randomly generated key and value (there will be exactly `hm_len`
/// entries, no more and no less).
pub fn fillHashmapWithRng(
    /// `*std.ArrayHashMap(Key, Value, _, _)`
    /// `*std.HashMap(Key, Value, _, _)`
    hashmap: anytype,
    rand: std.Random,
    /// Expected to provide methods & fields/decls:
    /// * `fn randomKey(context, rand: std.Random) Key`
    /// * `fn randomValue(context, rand: std.Random) Value`
    /// The length to set the hashmap to.
    hm_len: if (sig.utils.types.hashMapInfo(@TypeOf(hashmap.*))) |hm_info| hm_info.Size() else usize,
    context: anytype,
) !void {
    const Hm = @TypeOf(hashmap.*);
    const hm_info = sig.utils.types.hashMapInfo(Hm).?;

    hashmap.clearRetainingCapacity();
    try hashmap.ensureTotalCapacity(hm_len);

    for (0..hm_len) |_| {
        while (true) {
            const new_key: hm_info.Key = try context.randomKey(rand);
            const gop = hashmap.getOrPutAssumeCapacity(new_key);
            if (gop.found_existing) continue;
            gop.value_ptr.* = try context.randomValue(rand);
            break;
        }
    }
}

/// Downsample a random number generator to a smaller range.
/// This implementationc is based on the implementation in the rust rand crate
/// and ensures the same sequence is generated.
pub fn uintLessThanRust(r: Random, comptime T: type, less_than: T) T {
    comptime std.debug.assert(@typeInfo(T).Int.signedness == .unsigned);
    const bits = @typeInfo(T).Int.bits;
    const max = std.math.maxInt(T);
    std.debug.assert(0 < less_than);

    const z = (max - less_than + 1) % less_than;
    const zone = max - z;
    while (true) {
        const v = r.int(T);
        const m = std.math.mulWide(T, v, less_than);
        const lo: T = @truncate(m);
        if (lo <= zone) {
            return @truncate(m >> bits);
        }
    }
}

test "uintLessThanRust matches rust random sample implementation" {
    const epoch = 668;
    const max = 225582282719529290;

    var seed: [32]u8 = .{0} ** 32;
    std.mem.writeInt(u64, seed[0..8], epoch, .little);
    var rng = ChaChaRng(20).fromSeed(seed);
    const random = rng.random();

    var actual_weights: [rust_expected_weights.len]u64 = undefined;
    for (&actual_weights) |*actual| actual.* = uintLessThanRust(random, u64, max);
    try std.testing.expectEqualSlices(u64, &rust_expected_weights, &actual_weights);
}

test "WeightedRandomSampler matches rust with chacha" {
    // generate data
    var rng = chacha.ChaChaRng(20).fromSeed(.{0} ** 32);
    var random = rng.random();
    var items: [100]u64 = undefined;
    for (0..100) |i| {
        items[i] = @intCast(random.int(u32));
    }

    // run test
    const idx = try WeightedRandomSampler(u64).init(std.testing.allocator, random, &items);
    defer idx.deinit();
    for (0..100) |i| {
        const choice = items[idx.sample()];
        try std.testing.expect(expected_weights[i] == choice);
    }
}

const expected_weights = [_]u64{
    2956161493, 1129244316, 3088700093, 3781961315, 3373288848, 3202811807, 3373288848,
    3848953152, 2448479257, 3848953152, 772637944,  3781961315, 2813985970, 3612365086,
    1651635039, 2419978656, 1300932346, 3678279626, 683509331,  3612365086, 2086224346,
    3678279626, 3328365435, 3230977993, 2115397425, 3478228973, 2687045579, 3438229160,
    1973446681, 3373288848, 2419978656, 4248444456, 1867348299, 4064846400, 3678279626,
    4064846400, 3373288848, 3373288848, 2240211114, 3678279626, 1300932346, 2254827186,
    3848953152, 1867348299, 1194017814, 2254827186, 3373288848, 1651635039, 3328365435,
    3202811807, 3848953152, 2370328401, 3230977993, 2050511189, 2917185654, 3612365086,
    2576249230, 3438229160, 2866421973, 3438229160, 3612365086, 1669812906, 1768285000,
    877052848,  3755235835, 1651635039, 1931970043, 2813985970, 3781961315, 1004543717,
    2702218887, 2419978656, 2576249230, 2229903491, 4248444456, 3984256562, 4248444456,
    3339548555, 2576249230, 3848953152, 1071654007, 4064846400, 772637944,  4248444456,
    2448479257, 2229903491, 4294454303, 2813985970, 2971532662, 147947182,  2370328401,
    1981921065, 3478228973, 1387042214, 3755235835, 3384151174, 2448479257, 1768285000,
    102030521,  1813932776,
};

const rust_expected_weights: [1000]u64 = .{
    31062902069784538,  11382155169421619,  27392530810768476,  60952351212475329,  16048551006106618,
    4891334183545072,   199812930213193981, 38114256077859395,  42404129698994111,  97614856947956842,
    183625186665500139, 55561469963989707,  114806279863429445, 174695921848842231, 209254345337971893,
    176751855974666907, 169484242058825916, 53096067679482086,  177051337491659674, 163379749891795600,
    179717156427245839, 178284261730186885, 13607422465971250,  76897278175561060,  169514786933077178,
    211460631696319641, 180984625011128893, 201261559650451433, 53998990543213289,  212212464763738934,
    122182308760168308, 201313339960397649, 138853600416140498, 15840936011219485,  220243531954996575,
    43129268399614359,  83624162041749239,  68531200854737342,  20238773291476330,  120726007079673655,
    36112527943209629,  16126999239909142,  29275027929407865,  5887009332710451,   168624027757061195,
    105870571380400502, 206639295547003921, 130876855846148211, 92295433937266312,  70528184426375622,
    106086126786114105, 38329425424963691,  90596038042805790,  116919952096891754, 91971627753052638,
    60403602291203808,  100502810091763152, 95943332786405300,  193574871379632726, 211185654902527801,
    27951750663881589,  136547636443172802, 136477388888229124, 21501939613854240,  26875018413785605,
    19544848883098136,  112130757298565812, 160096482910593195, 189684507028605919, 53346286272790554,
    74449986428209599,  192075576337681317, 184020910724247867, 81504263034798119,  5008075603845954,
    70371491455308146,  152497921257275423, 173116009057148050, 126479259987573853, 62808832814697156,
    81313285680298593,  197206172542435502, 207678950753680457, 68634769585973356,  103329383314119322,
    15612010854857805,  95652758948599313,  193840665697371308, 40436117617628716,  136666096174804823,
    114109677692270685, 134835781687817420, 126979490490304778, 133130031919014684, 88716298854176907,
    96433815902451829,  167010031952026650, 31312947532485227,  63563803612839751,  217517656852498585,
    167387249853442789, 55473969034735540,  220364241503524633, 49505326247438056,  118292723882226683,
    59826362073341238,  102079527637092467, 102780283920088834, 170690065394018959, 208368749160747228,
    64029537859501852,  174321195693103576, 34567353504495939,  82733122980746081,  51967188594525078,
    7294333871397908,   29693330573019962,  17906707212534847,  180616801806423214, 121814125323587262,
    138043979178423794, 132860448555391287, 181970312522623747, 61607190924866110,  45373973520752765,
    93554301288785464,  15030304878540079,  34524016611890422,  189654028288187211, 202244516916481056,
    147671786941464044, 81425718705006339,  14796576323773347,  114444347983856750, 82570712424436424,
    194242359364255899, 49002816643634281,  77826672870319414,  222651410337686689, 213438864495506822,
    174477460640490886, 66731544780146025,  170346500441889069, 181659961470462075, 154674221332016591,
    113425837541056524, 52716010748215559,  137362673540743682, 79637123099361134,  211527183219928196,
    46216551169292287,  210490931871709747, 107818229788331266, 88339370430373535,  36301725307061361,
    13674253023679808,  189161621776131128, 22416520691217779,  57153556649406078,  122621412113233743,
    222876810293200876, 39431124462639490,  171817277720293787, 49295514888251301,  189194993435557595,
    149489634347864602, 136157773670081052, 144148762679394264, 31513829081899899,  118619108537013982,
    67919385787855129,  183599505539306939, 6135238904359892,   145344879132999475, 125927162572723324,
    132999273259328842, 29859443519365911,  182538378182666614, 83056759677189046,  115261678724947714,
    3226354947013693,   206458880875145534, 17711070875675029,  40145591504248637,  120026150591501692,
    9776364782824250,   154477817286457771, 146329332162664379, 83285540909868345,  102992396073258575,
    186312391750715173, 29903465754322632,  131758918395242607, 153852438313836614, 184901640414394466,
    57657516032986461,  160889616177139424, 145407325553572724, 146882309488697318, 14525387488121559,
    198102312680484679, 2549831636293877,   116472779529269255, 2544082799275693,   157180563503236809,
    171825838688405310, 174671581660418297, 207486280158005828, 224566307245460372, 211705395306135772,
    180709087411285685, 149557488302324327, 111276910651978813, 179539066277759307, 30556787036384378,
    128102221654749622, 195218505405063403, 56643611476622255,  85223089879500001,  44950766669725679,
    181989839811012637, 150747831158568845, 213860551541332756, 70470135066743169,  108477059400082455,
    32396911976163807,  132362403518784605, 143623166587106906, 146676226843779783, 25569375527732198,
    83553329486482814,  135135921027655915, 181746137218441637, 13956129527895611,  161703140502368433,
    120495335550494499, 179934083704642691, 199832318448060089, 4240639059600682,   134383311265528075,
    83804066018511674,  179815121622909188, 115206705519909353, 164243413281949044, 120083823137516686,
    177755603738479717, 189338067965532732, 51640166561777890,  192732089616444940, 123274033917931408,
    183755501601791539, 138790519374521271, 19184796812646241,  134536089910786195, 24359825830506156,
    56695580144708905,  15860910502814504,  180406897857210923, 132364160477296791, 49917736634289217,
    20260732021263483,  48094851054391121,  194446815406340014, 131001037763091890, 28729398634759588,
    212739639517588159, 137921138738058661, 174458068449970819, 91668764434001059,  156106607289921241,
    157766418094380801, 154097400899036225, 92334488684668686,  48024742984948974,  173868575648006392,
    76281924247812357,  202706098253646696, 184419926108838786, 28928718994661477,  201258115689541052,
    58606597162996373,  222213094579433276, 108331561969183650, 154896692533611583, 120780341333703401,
    157381151947229371, 13195186007950911,  46583321403053389,  225204971267440566, 27524263542151795,
    50452044658693863,  169274421783175301, 67248475418669836,  195806175497473319, 35809150556536662,
    16781515700247479,  83406255609708391,  154290128524247418, 94102005605378543,  157033183911364581,
    174105247427289206, 25468761064469843,  197843885125502440, 187445567535340187, 132388353819500165,
    94386783518358670,  167609944714827832, 158777804043381945, 5055065668929526,   94835507579084829,
    150886827618989377, 42571298337529464,  172407493526950236, 215258757221768834, 144077347515960368,
    20623155350072686,  22472629113059569,  213657988703456281, 42223522129154283,  100010141381318515,
    135985264231644609, 17273053536876251,  135636021657555449, 198918751329590511, 203695415453787237,
    171363764203615635, 207152528386690003, 193241305170867887, 216839843869965421, 26389740361320213,
    588068555282608,    5652563854737700,   55032158197766599,  137401034110042589, 25673558852213716,
    194925062564925426, 95817443943946545,  99106568619325024,  29866660855801702,  80054806371226231,
    150624654579979572, 34846543353127624,  52312585235895186,  206254651023775856, 96834603601123574,
    20732473333845356,  95625977929824258,  41399330189278030,  172672137144640457, 149009478409524770,
    179352424464345772, 194589909260640724, 141064301661742866, 167987627243377080, 65774930779843737,
    3407147855327345,   159341191903942883, 164556742707079386, 221123472195644060, 63809148911699323,
    88168017375818916,  153045707722108760, 9924561552372924,   38554128182831767,  94414094085472921,
    114607818407329748, 86126888777932771,  91593868546395569,  143705759562225395, 223123219686514945,
    41894634313758921,  81845987595028615,  66562560779938849,  102828949363883307, 69464548681286665,
    99023912076421815,  35443602142909634,  225219716304854650, 89684654507526755,  153130119361306244,
    40171757456611874,  177326005657817212, 43744852377663794,  20547943531078145,  45662586339892141,
    131039437694044221, 178807411783905523, 104401616837768425, 197942130271128843, 7802347200645357,
    74693650088962505,  81258255739110254,  113204142378989681, 129613717675883672, 214667923992454526,
    91579148349538842,  169855888023884643, 50968372162015669,  170135519987017494, 19849505935129355,
    107623652797027124, 179567066103995589, 203489538027390518, 51287522978090893,  173397432255756070,
    17700705457175428,  76854856278744797,  102550230143714249, 148314140815898886, 125811711197065933,
    191754740369000982, 212560936627632534, 64817451494287237,  25576759339662940,  53912313226293837,
    131637772668310053, 30214974149627761,  119708509144134901, 165969214608539584, 95532331282634972,
    167105107783934496, 49017853504641610,  105695266265309548, 31415630073553954,  117599399958706170,
    43519766857764202,  207202688365886501, 45717242225431841,  71470965743893397,  152049854048509134,
    180918290925210386, 130172449275488632, 76637886601079509,  159883320605511133, 53921530557666139,
    177936913440415284, 12612250440631447,  149536208326396174, 29868750812561361,  140799167794532746,
    164578193598758139, 211643387107550219, 49809944915974105,  101950109038541608, 160549434064237405,
    111902007979428004, 170968663794623260, 121506977097456,    195588380186072561, 3160073930554364,
    223250022726416840, 82624380803322217,  12701208124334362,  214771089199552534, 187816738107550150,
    186059416224811534, 187970289217337528, 92984549210834480,  129756847511657851, 125617890186218699,
    149117377617386013, 168383809716937082, 137935468401066880, 166488625999463587, 115765117383074737,
    204751524086271116, 172617646259456216, 131749400098690613, 129138972987664783, 59509506913983529,
    60634344326730088,  142593617935369587, 190238490252134005, 64227520227973494,  211332794387330389,
    37968658791123924,  44044754378681910,  109173202396493812, 203572137931551132, 42377434098281910,
    48292443677853420,  14051267738923100,  23090257156716228,  125916473545662336, 172755167690532579,
    214934634509912627, 201262317607872078, 59864922085527344,  46901554322460919,  89114314812957673,
    193858950356327397, 178953486901853898, 85598259024085726,  75718678891758881,  177710404378348475,
    170731784935494535, 72795716502427694,  42843318063199726,  16779879269831186,  133194424530016201,
    31268842648513743,  5041065797483705,   16798354384786100,  73457314826189138,  65081383798385054,
    172819366612138454, 185906145115290670, 93606157599075714,  51681984432396538,  6010727292284944,
    209863813533643122, 204939752643617978, 34011683528703588,  111893894258854258, 147224187060873591,
    204101995215537799, 15745956264245964,  13318006435774244,  36960330134842202,  96736084088084878,
    210502156692533137, 95698127924754377,  178907742473360549, 80578877864219592,  214970245067001619,
    98554409651380577,  75655927181186904,  107654703615807754, 8727275549429336,   147810264585736580,
    177811227761706879, 75636480821282854,  148514842148369476, 125808438107638905, 58711264260187222,
    142684717064336826, 1479821743710565,   143548571331234801, 167037248131617759, 29631266637050041,
    193086195621328600, 4322114166709290,   198037125208758315, 84187595714943294,  154294023172609900,
    21626360566204341,  133883382457378492, 206103056345361350, 167900254436372692, 105175409238685832,
    55161657376239089,  187410533844041429, 98110101787273100,  65257907976737968,  100643360452756866,
    209389618397679233, 56192218489606148,  127150813376877071, 45754652912687900,  37031331211893027,
    178636639136789245, 97306546686260854,  144821541799332330, 154025685076436575, 144905455907628955,
    204108187108054800, 127537522520031255, 53431798321314223,  127390210242929977, 137034858194476243,
    4024295160692592,   183933244737997717, 124054770736883590, 69808058958951838,  75821348091227229,
    67616864878329089,  47031372902985300,  161863069240568387, 93607546510239064,  102354393472979351,
    14498977657149311,  19309099569930179,  53440933212137731,  160331221908676507, 204839316112895356,
    22830488800158864,  101572273530149487, 96144514184120399,  132420649546431879, 197691849056035516,
    82825969033505401,  137863321542054892, 83479226996217983,  114808556604009727, 174133622004543916,
    115997824665603835, 190855160838733325, 197494246535804805, 135905180393355590, 170662594317090120,
    23700733265016654,  33944197945815824,  211595857393548724, 221409402400875714, 121864092924100010,
    135584812162085872, 103923898157251157, 78305723954620893,  144175668591229911, 38663117298130556,
    113915831197788342, 157998573577920223, 54214670537593696,  113013573379039766, 126342378614831747,
    168056251399160126, 141746602428773638, 187151177377576191, 211666614396241362, 146437820575279587,
    105586996688033462, 78256654773957154,  213336498756432298, 29515359353313442,  152679976182726096,
    30984689934107238,  75901738098331621,  34108682454564821,  92430745467353319,  82130713955334265,
    17336243635504468,  75822791852085129,  128297964556593069, 14234089369567240,  141078105797570393,
    14888690465088141,  197806921962952659, 118262078242232114, 11658218991284042,  74634180408340320,
    82527152627636797,  108913925940752110, 61453398758134277,  63644257962715166,  191457718257776625,
    4367954321278823,   86383503003466497,  185170317268942689, 94206460641960435,  8359354152286605,
    73008577255235868,  146243684575705626, 109405804750160032, 61169105135327996,  149856657566628314,
    217343813357081333, 123949111680799482, 81307197741662534,  152105262696749427, 35407903602710960,
    190052921672892349, 168504983599664856, 172617856573454037, 217463411379699535, 185261153131993256,
    91603851989262557,  163106813819192987, 28363221390678625,  169578019619832264, 25991528652760032,
    118319271117359212, 61216259721292016,  143024282285973082, 102635160683582657, 50181798547687568,
    42761389078282330,  217466694234184284, 22081237404706235,  66522398503582993,  214540943617269843,
    26410481246392040,  144021825924567384, 145570859750106114, 197505790300542957, 197370984290377656,
    217343298719828706, 177913541675397295, 8082916329422731,   51508381367001582,  79647182720442281,
    14108691634871802,  187738459118012084, 193824195644994135, 224761437117413693, 123057497888020956,
    57894864393449413,  59933548115841955,  189613749164546297, 85629072986218667,  196401642360854739,
    156883814602409749, 201767846626109286, 139851771674417879, 144052570844888069, 105660878110269119,
    88329776365725660,  70265378703302614,  66709629450046652,  143432573602915045, 96641082058760517,
    174299708831781328, 107031469831211802, 104337874515487643, 28850982906491960,  3770974136755161,
    58192511091675737,  208407107144558038, 50977029101718003,  170848290436415997, 210107750606079912,
    190285263628188947, 38222763111641625,  175949239476871136, 162163769412756210, 131069163457960484,
    62184425376907947,  41984209039837339,  181327691512613452, 197835507063676281, 197600451127984282,
    130005708520968102, 169436681437780909, 197467637930532393, 209074990059455509, 137746513084288790,
    113253666243374267, 119538390463146557, 75637251984909437,  132485102588900593, 57852136885618591,
    120316436801881549, 132169045138091766, 124468945242604917, 136494783027007831, 92426785268027979,
    181516159864349221, 166853782139216284, 217691285768480513, 187018342968716262, 111254260366065782,
    4987198678008930,   29531083549207405,  21308984251031521,  54266959486576014,  20759386542717322,
    158614425386723857, 65229186015124225,  74845445056152549,  65130580872483548,  72337501901977070,
    159933232140587248, 119999282326610470, 55655467964808587,  137155154083631015, 127571417255971460,
    43770483944691698,  120673667476911979, 196631338579713335, 9955205394885243,   160321120855207800,
    105341843025987901, 176122070586455313, 222944990823274330, 181045970802661345, 78451654903574965,
    77738262794760527,  56028171453259208,  160928146118234232, 211897566947734224, 206108363831420987,
    48808976021201882,  44890210047051238,  67233839816293955,  94388975761024061,  67707801020423688,
    176576391479105046, 157057321693279835, 79033119067749766,  79156954090371543,  101223524434664754,
    145568761602827106, 72945918520192537,  1484900910276455,   72323639610226291,  192081122368709194,
    175199074558083152, 702015270153953,    125168037894294452, 6591021662903884,   51275981649376230,
    59980622426801417,  201896534287537755, 61758338940581761,  13454291133486399,  92743446697054634,
    146764624778231578, 121901032773678462, 200403666008974162, 59605844334064124,  86782528281040113,
    100878543171257573, 206880206669118181, 84456941734623326,  26196193838551430,  98409579580995120,
    102949519326817393, 170337604204633396, 51194404870468822,  126241123568858133, 5908262677098941,
    88688681081621726,  121677379738558952, 148067220988191040, 160512594053679368, 98077390852056942,
    6258214675904343,   155527873102388459, 119755839689693088, 180721166795520999, 167314996728126700,
    5903205988819758,   186907838713062419, 194889024039921653, 204899010660454682, 215341437464616290,
    56165835324573391,  108212062504010895, 145100756470273464, 179241023761198154, 14903574486373483,
    142251589357906675, 62085116279984451,  178041835157283939, 124708515432846336, 701430436185335,
    133951419574273876, 175061730731951640, 100516405484481337, 19624693464625551,  76980620548329162,
    208188714272995690, 150387126364980844, 56812198755280841,  8579622337306025,   133964676680952518,
    118962981067940687, 178340054291096091, 114903761358909813, 47608048165009785,  98312695070019037,
    215143315906440334, 135850729410617930, 22875582774674668,  211395492022933390, 100464632120837408,
    180030347904041841, 127653058572472372, 17277763035803751,  115712749681989106, 182646602364860852,
    23067630942693062,  106945906453900117, 207624959795358723, 63566696829602481,  172010563297258489,
    41245690569780435,  20295442260563797,  168572582605760520, 95026244492578552,  137204804438967980,
    36043988140569320,  89725734455049916,  41121825632156526,  11464890278390745,  92486340986115035,
    41247989919663788,  27437304312726619,  78946384588838694,  202306008484308471, 141283124827334872,
    15149885953682648,  105052718771207130, 93007288401648444,  96506463779529301,  26156947180289304,
    164879588146433764, 124866914331450735, 2958594716786058,   206339303989790563, 3579798043059788,
    67349919375139501,  170711730505131607, 144992818219067542, 30670516022729165,  138907584615587438,
    127817381089378212, 114871171103897336, 165002752098828949, 129783111060717438, 141402390895707373,
    49789905082632543,  44642008510651678,  142897357041335417, 15619830375298759,  108389393594576866,
    2049459598661566,   186002123029450793, 115978668653229962, 25505487210171515,  5594356300076705,
    218194016043222958, 131099199892564490, 161829150048369624, 107822998318207832, 97744594758044930,
    159723516838411175, 137761953409828195, 17934832723300816,  199618139361605350, 152488795447658825,
    59285081064243544,  189888454568762638, 214109977383678979, 106069302482628549, 125828040156667548,
    60448978859164630,  6664155818271300,   32057213396689758,  134359424014350909, 101706944218512714,
    34363235225823814,  224815739117243291, 154174716140977289, 186508220141956340, 81371844716237169,
    209604334597774355, 69722560753843310,  26554189446811940,  112142350402187528, 55025340774553552,
    150245030477280661, 213624595435805867, 98539226549693351,  33801042929801430,  203768025145824241,
    85942546992148859,  75920971919241723,  178282653246684682, 107180956559443505, 5383407800161210,
    25924734343585423,  113505140769538087, 158294491487555208, 202058441263127158, 23754109538483632,
    164332741174520337, 177386067656078943, 63092035208918209,  105193165892558811, 90842259062651642,
    200087190942123447, 118864219926511175, 178914468731322740, 123929446491278238, 83233452188148132,
    130678632301769656, 148140195893539773, 189717099709818244, 3866162913691558,   165276931946696165,
    195669972620483101, 220740178411808744, 218597519430516114, 181499314628684163, 56281591694254078,
    112584340323866656, 73160071773275256,  216001312005955998, 184061143539899962, 132782144182150573,
    40566523540155677,  171562338978082216, 151758301674069632, 173398251098334249, 63757156897079302,
    81032160488073578,  173298561206951917, 154421360720272045, 15981567533895039,  88393403508710277,
};
