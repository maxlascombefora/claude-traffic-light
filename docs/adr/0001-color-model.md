# Color model: split states, red reserved for hard blocks

The Light maps Session Status to color as: 🔴 **Blocked** (waiting on a permission prompt),
🟡 **Your Turn** (finished, awaiting my reply), 🟢 **Working** (actively running), and
**dim/off** when everything is Idle or no Sessions are open.

We chose this "split" model over (a) an attention model where red covers both Blocked and
Your Turn, and (b) the literal traffic metaphor (green = go/running). The split keeps red
scarce so it only fires when something is genuinely urgent (a hard block), while still
distinguishing "your move" (yellow) from "leave it alone" (green).

**Surprising, so recorded:** 🟢 green means *busy*, not "all clear," and 🔴 red does **not**
fire merely because a Session finished. A future reader would otherwise assume the literal
metaphor and "fix" it. The trade-off: green-means-busy is counter-intuitive, and the single
Light can only show the one highest-urgency Status at a time (see aggregation).
