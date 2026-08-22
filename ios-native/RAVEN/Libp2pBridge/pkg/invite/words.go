package invite

import (
	"crypto/sha256"
	"strings"
)

// ravenWords is the frozen 256-word list used to render a speakable four-word
// "face" of an identity key ("copper raven north lantern"). It is a lossy
// verification aid only — like a safety number — never an encoding.
var ravenWords = [256]string{
	"acorn", "agent", "album", "alien", "alloy", "amber", "anchor", "angel",
	"apple", "apricot", "arrow", "aspen", "atlas", "atom", "aurora", "autumn",
	"bacon", "badge", "baker", "bamboo", "banana", "barley", "basil", "basin",
	"basket", "bat", "beach", "beacon", "bean", "bear", "beaver", "bed",
	"bee", "beetle", "bell", "belt", "bench", "berry", "bicycle", "birch",
	"bird", "bison", "blanket", "blaze", "blend", "blizzard", "bloom", "blossom",
	"blue", "board", "boat", "bobcat", "body", "bolt", "bone", "bonfire",
	"book", "boot", "border", "bottle", "boulder", "bowl", "branch", "brass",
	"bread", "brick", "bridge", "bright", "brook", "brush", "bubble", "bucket",
	"bugle", "bulb", "bull", "bunch", "burrow", "butter", "button", "cabin",
	"cable", "cactus", "cake", "camel", "camp", "canal", "candle", "canoe",
	"canvas", "canyon", "cape", "caramel", "cargo", "carpet", "carrot", "cart",
	"castle", "cave", "cedar", "cell", "chain", "chair", "chalk", "charm",
	"cheese", "cherry", "chess", "chest", "chick", "chief", "chill", "chimney",
	"chip", "chocolate", "cider", "cinema", "circle", "citrus", "city", "clam",
	"clay", "cliff", "cloak", "clock", "cloud", "clover", "clove", "coach",
	"coast", "cobra", "cocoa", "coffee", "coin", "comet", "compass", "cone",
	"copper", "coral", "corn", "cosmic", "cotton", "cougar", "couch", "cover",
	"coyote", "crab", "crane", "crate", "crayon", "cream", "creek", "crescent",
	"crew", "cricket", "crown", "cube", "cupcake", "curtain", "curve", "cyan",
	"dahlia", "daisy", "dance", "dawn", "deck", "deer", "delta", "denim",
	"desert", "diamond", "dice", "diesel", "dinner", "dish", "diver", "dock",
	"dolphin", "domino", "donkey", "donut", "door", "dove", "dragon", "drain",
	"drama", "dream", "dress", "drift", "drum", "duck", "dune", "dusk",
	"eagle", "earth", "easel", "echo", "eel", "egg", "elbow", "elder",
	"elk", "elm", "ember", "emerald", "engine", "envelope", "eraser", "evening",
	"evergreen", "falcon", "fawn", "feather", "fern", "ferry", "fig", "finch",
	"firefly", "fjord", "flame", "flamingo", "flint", "float", "flute", "foam",
	"fog", "forest", "fossil", "fountain", "fox", "frame", "frost", "fruit",
	"fungus", "funnel", "gadget", "galaxy", "garden", "garlic", "gate", "gazelle",
	"gecko", "gem", "giant", "ginger", "glacier", "glass", "glimmer", "globe",
	"glove", "glow", "gold", "goose", "gorge", "granite", "grape", "grass",
}

// Words renders a deterministic, human-speakable four-word face of a public
// key. Same key always yields the same words; the mapping is one-way.
func Words(pub []byte) string {
	sum := sha256.Sum256(pub)
	parts := make([]string, 0, 4)
	for i := 0; i < 4; i++ {
		parts = append(parts, ravenWords[sum[i]])
	}
	return strings.Join(parts, " ")
}
