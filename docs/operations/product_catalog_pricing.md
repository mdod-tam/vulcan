# Product catalog pricing and unresolved information

Research checked November 13, 2026; Moshi addition checked November 15, 2026.
All seeded amounts are USD reference prices.
The user-supplied price list does not specify tax or shipping terms.
The source catalog is [products.yml](../../db/seeds/products.yml).

The original list contained 46 unique entries. The catalog retains 43, replaces
the generic MacBook placeholder with 13-inch and 15-inch MacBook Air models,
and excludes Hamilton CapTel at the user's direction because it is obtained
directly through Hamilton. Discontinued ClearSounds CSC600 is excluded. It
includes six earlier additions: Dot Pad X, TD I-Series, JAWS, ZoomText, Tatum1
and myMMX db, and adds Serene HD-40P, Clarity P300-HCO and the Moshi wrist/body strap.
Repeated products across disability groups are one row with combined eligibility.
JV35 and JV35W remain separate: [Clarity lists both button-contrast variants](https://www.clarityproducts.com/amplified-and-low-vision-phones).

Of 54 entries, 31 have a sourced reference price and 23 explicitly have
`msrp: null`. Each unknown has a `REVIEW` comment beside its seed value. There
are two entries with no manufacturer: Tap-It remains unresolved, while Windows
laptops intentionally remain generic because the program does not supply one
consistent brand. Nine entries have no exact model number. Further configuration
and bundle gaps are identified below.

## Price basis and seed behavior

The existing `msrp` field holds explicit published MSRP where found; otherwise
it holds the manufacturer's published regular/direct price or the SkyAngel
supplier's regular list price. The P300-HCO uses Teltex's public supplier price.
The four supplied SquareGlow prices take precedence
over public listings and are labeled as user-supplied reference prices; the
image labels its column PRICE, without explicitly calling it MSRP.
These alternatives are identified per row and
are reference prices, not a claim that every source formally labels its value
MSRP. Web-researched prices exclude sale, trade-in, financing, subsidy and
insurance offers; the supplied prices are recorded as given.
The Moshi strap retains the user's exact product name, SKU `99MO2252613` and
$39.95 USD price. Its manufacturer US listing also displays $39.95; the page
does not independently show the SKU in its readable product details.
Historical launch prices are explicitly identified. `null` means unknown,
not zero or free.

Phone/tablet prices refer to the stated configuration. Those configuration
notes are also seeded into `compatibility_notes`; storage, carrier and
connectivity still need to be chosen for an actual order. A reference price
does not establish current stock or a final supplier quote.

`Seeds::Products.call` finds each row by its immutable `catalog_key`, creates it
when missing, and refreshes the attributes specified in the seed. Seeded names,
MSRP and other metadata replace staff edits; an explicit `null` clears the field.
Attributes absent from the seed remain unchanged, including `archived_at`, and
linked resources stay attached. Manually added products with no catalog key are
untouched. Active keyed rows removed from the seed are discontinued, preserving
their IDs and all purchasing, evaluation and training history. Repeating the
refresh does not create duplicates or reset a discontinuation date.

Normal product validations apply to the entire transaction. A referenced exact
manufacturer/model cannot be replaced or reverted to a draft. For a different
SKU or exact model, add a new product with a new catalog key and retire the old
key instead of repurposing it. A rejected update rolls back the refresh. The
legacy catalog key for BlindShell Beep stays stable because its verified name
correction identifies the same product.

The two MacBook Air entries inherit the former MacBook placeholder's DeafBlind
eligibility. The Windows laptop placeholder remains separate. Existing database
rows, including a previously seeded Hamilton draft, are not deleted. An active
keyed row absent from the current seed is discontinued by the refresh.

The user excludes discontinued products from this seed. Clarity P300-SP is
not added, and the existing black ClearSounds CSC600 row is removed; both are
listed in Teltex's discontinued-product archive. The refresh discontinues their
active keyed rows without deleting historical records. Serene HD-40P has active
manufacturer and supplier listings, with a manufacturer stock warning retained in
its notes.

## Seeded reference prices

| Product | Seeded USD | Basis, configuration and source |
| --- | ---: | --- |
| Apple iPhone 18 Pro | 1,199.00 | 256GB starting list price; [Apple announcement](https://www.apple.com/newsroom/2026/09/apple-debuts-iphone-18-pro-and-iphone-18-pro-max/). |
| Apple iPhone 18 Pro Max | 1,299.00 | 256GB starting list price; [Apple announcement](https://www.apple.com/newsroom/2026/09/apple-debuts-iphone-18-pro-and-iphone-18-pro-max/). |
| Apple iPhone 17 | 929.00 | Current 256GB, connect on your own later; [Apple store](https://www.apple.com/shop/buy-iphone/iphone-17). Different from its $799 launch starting price. |
| Apple iPhone 17 Pro Max | 1,199.00 | Historical 256GB launch list price; current availability needs confirmation; [Apple announcement](https://www.apple.com/newsroom/2025/09/apple-unveils-iphone-17-pro-and-iphone-17-pro-max/). |
| Samsung Galaxy S26 5G | 799.99 | 128GB unlocked, SM-S942UZKAXAA; explicit [November 2026 Samsung MSRP](https://images.samsung.com/is/content/samsung/assets/us/business/solutions/industries/government/msrp-price-sheets/Samsung-HHP-MSRP-Price-File-November-2026.pdf). 256GB is $999.99. |
| Samsung Galaxy A57 5G | 599.99 | 8GB/128GB unlocked, SM-A576UDBAXAA; explicit [November 2026 Samsung MSRP](https://images.samsung.com/is/content/samsung/assets/us/business/solutions/industries/government/msrp-price-sheets/Samsung-HHP-MSRP-Price-File-November-2026.pdf). |
| Google Pixel 11 | 899.00 | 256GB starting list price; [Google announcement](https://blog.google/products-and-platforms/devices/pixel/google-pixel-11-pro-xl/), [US store configuration](https://store.google.com/us/product/pixel_11?hl=en-US). |
| Google Pixel 11 Pro XL | 1,299.00 | 256GB starting list price; [Google announcement](https://blog.google/products-and-platforms/devices/pixel/google-pixel-11-pro-xl/). |
| Apple iPad Pro 11-inch M5 | 1,199.00 | Current 256GB Wi-Fi, standard glass; [Apple M5 configuration](https://www.apple.com/shop/buy-ipad/ipad-pro/11-inch-display-256gb-space-black-wifi-standard-glass). |
| Apple iPad Pro 13-inch M5 | 1,499.00 | Current 256GB Wi-Fi, standard glass; [Apple M5 configuration](https://www.apple.com/shop/buy-ipad/ipad-pro/13-inch-display-256gb-silver-wifi-standard-glass). |
| Apple iPad mini A17 Pro | 499.00 | Historical 128GB Wi-Fi launch list price; [Apple announcement](https://www.apple.com/newsroom/2024/10/apple-introduces-powerful-new-ipad-mini-built-for-apple-intelligence/). Confirm availability; newer mini generations have different prices. |
| Apple MacBook Air 13-inch M5 | 1,299.00 | 10-core CPU, 8-core GPU, 16GB/512GB, reference MDH74LL/A; Consumer MSRP column in [Apple's September 2026 NASPO sheet](https://www.apple.com/education/purchase/contracts/docs/NASPO_PSS_Apple_Branded.pdf), excluding the contract discount. |
| Apple MacBook Air 15-inch M5 | 1,499.00 | 10-core CPU, 10-core GPU, 16GB/512GB, reference MDV94LL/A; Consumer MSRP column in [Apple's September 2026 NASPO sheet](https://www.apple.com/education/purchase/contracts/docs/NASPO_PSS_Apple_Branded.pdf), excluding the contract discount. |
| ClearSounds CSC500 | 89.95 | Manufacturer regular price, excluding $79.95 sale offer; [ClearSounds](https://clearsounds.com/collections/corded). Listed sold out. |
| BlindShell Classic 3 | 790.00 | Current direct US price including cradle/accessories; [BlindShell](https://www.blindshell.com/us/eshop/blindshell-classic-3). |
| Clarity JV35W | 149.95 | Distributor explicitly labels MSRP for part 76557.101; [9 to 5 Computer](https://global.channelonline.com/9to5computer/storesite/Products/overview/M016459810). Confirm current supplier quote. |
| SquareGlow Home Notification Kit | 264.99 | Non-Wi-Fi HomeKit, two flashers, doorbell and Phone/VP signaler; manufacturer [regular price](https://www.squareglow.com/products/squareglow-home-kit). |
| SquareGlow Smart HomeKit | 415.00 | User-supplied SquareGlow price-list image, November 13, 2026. Confirm bundle contents. |
| SquareGlow Smart Strobe Alert | 79.99 | User-supplied SquareGlow price-list image, November 13, 2026. |
| SquareGlow Adapter | 9.99 | User-supplied SquareGlow price list. The user confirmed Adapter is the model name. |
| SquareGlow Chime Kit | 49.99 | User-supplied SquareGlow price-list image, November 13, 2026. Confirm kit contents. |
| Freedom Scientific Focus 40 Blue, fifth generation | 3,748.50 | Manufacturer direct price, SKU 900728-007; [Vispero](https://shop.vispero.com/products/focus-40-blue-5th-generation). Listed on backorder. |
| HumanWare Brailliant BI 40X | 3,759.00 | Manufacturer US regular list price; [HumanWare](https://store.humanware.com/hus/brailliant-bi-40x-braille-display.html). |
| SkyAngel 911 Pendant | 229.99 | Supplier regular price for 911FD, excluding $159.99 sale; [Assistive Technology Services](https://www.assistivetechnologyservices.com/onsalenow.html). Confirm intended version and cellular compatibility. |
| SkyAngel Wrist | 189.99 | Supplier regular price for SkyAngel911Wrist, excluding $159.99 sale; [Assistive Technology Services](https://www.assistivetechnologyservices.com/onsalenow.html). Confirm version and cellular compatibility. |
| BlindShell Beep | 30.00 | One object finder, requires Classic 2 or 3; manufacturer [US price and exact model](https://www.blindshell.com/us/eshop/blindshell-beep-282). |
| Hable One | 239.00 | Manufacturer direct US price; [Hable](https://www.iamhable.com/en-am/products/hable-one-keyboard). |
| Enabling Devices Easy Flex Stylus | 80.95 | Manufacturer direct price for item 9079, including straps and one tip; [Enabling Devices](https://enablingdevices.com/product/easy-flex-stylus/). Replacement tips item 9091 are separate. Verified using indexed primary-source product/category content because direct page access returned 403. |
| Moshi 2-in-1 Wrist/Body Strap with Adapter / Midnight Gray | 39.95 | User-supplied name, SKU `99MO2252613` and price. [Moshi's US Midnight Gray listing](https://us.moshi.com/products/2-in-1-wrist-body-strap-with-adapter?variant=47163633238154) confirms the color, included adapter, wrist/crossbody design and direct USD price. |
| Serene Innovations HD-40P | 139.95 | Manufacturer regular reference price, excluding the $129.95 sale price; [Serene](https://www.sereneinnovations.com/products/high-definition-amplified-speakerphone-with-photo-memory). Model HD-40P; currently marked sold out by the manufacturer. |
| Clarity P300-HCO | 369.95 | Public supplier price for the complete telephone/AAC kit, not explicitly MSRP; [Teltex](https://teltex.com/p300-hco/). Tablet model and AAC application/license require procurement confirmation. |

HD-40P is one amplified photo-dial speakerphone, classified as `Amplified Phone`
and `Memory Aid Device`, with existing hard-of-hearing, low-vision and mobility
eligibility. Its amplification is incoming, not outgoing speech amplification.
The current application has no separate cognitive eligibility group; this
seed-only update does not add one.

P300-HCO is one `Speech Device` kit eligible for speech, rather than separate
tablet, keyboard and speaker products. Confirm its supplied configuration and
telephone compatibility when ordering.

The Moshi strap is an `Accessory` available to every existing disability group,
including DeafBlind. It is a phone-carrying accessory with no mobility-only
restriction; the existing mobility-only mount and stylus eligibility is unchanged.
The adapter must fit the selected phone case. Group eligibility does not establish
compatibility with every device or case.

TruTone EMOTE uses `atos-medical-trutone-emote-electrolarynx`, with Atos Medical
as manufacturer. The former `provox-trutone-emote-electrolarynx` key is retired.
The shared refresh archives its active row through normal model validation,
preserving its original identity and linked history instead of changing a
referenced exact model. The corrected catalog entry has its own ID; MSRP remains
unverified.

The supplied Smart HomeKit and Smart Strobe prices differ from the public
[Smart Home Kit listing](https://www.squareglow.com/products/copy-of-smart-flasher-kit)
($365.99) and [Smart Strobe listing](https://www.squareglow.com/collections/accessories/products/smart-strobe)
($89.99) found during research. The seed uses the supplied values.

## Excluded discontinued products

| Product | Reason and source |
| --- | --- |
| Clarity P300-SP | Teltex places the exact outgoing-speech phone in its [discontinued archive](https://teltex.com/manual-resources-discontinued-products/p-300-sp/), without a current selling price. [Texas STAP's](https://stap.hhsc.state.tx.us/Home/ViewEquipmentList) $139.95 equipment value is a reimbursement reference, not MSRP; it is not used as a seed price. |
| ClearSounds CSC600 (black) | Exact SKU CS-CSC600 is in [Teltex's discontinued archive](https://teltex.com/manual-resources-discontinued-products/clear-sounds-c-s-c-600/). The removed row is distinct from white WCSC600. |

## Unknown prices and information to resolve

Public prices for a different model, bundle or license are reference leads only;
they have not been inserted as an exact MSRP.

Bellman & Symfon Visit stays in draft until the exact bundle is selected.

| Product | Missing information / research result |
| --- | --- |
| Samsung Galaxy Tab | Samsung selected by the user. Exact Galaxy Tab model, size, storage/connectivity configuration and MSRP remain unselected. |
| Windows laptop | Intentionally generic at the user's direction: the program does not consistently supply one brand. Manufacturer/model and MSRP depend on procurement. |
| Clarity JV35 | Current-generation MSRP unverified. [VoIP Supply](https://www.voipsupply.com/clarity-jv-35-amplified-desk-phone) lists $149.95 MSRP for JV-35B with a 37dB description; [Clarity's current model](https://www.clarityproducts.com/amplified-and-low-vision-phones) is 50dB. Confirm generation/part before adopting that price. |
| Lingraphica TouchTalk | No public fixed manufacturer MSRP located; [manufacturer device page](https://lingraphica.com/aac-devices/touchtalk/). Request configuration and quote. |
| Lingraphica MiniTalk | No public fixed manufacturer MSRP located; [manufacturer device page](https://lingraphica.com/aac-devices/minitalk/). Request configuration and quote. |
| Lingraphica TouchTalk Plus | No public fixed manufacturer MSRP located; [manufacturer device page](https://lingraphica.com/aac-devices/touchtalk-plus/). Request configuration and quote. |
| Provox TruTone EMOTE | Corrected manufacturer to Atos Medical; Provox is a brand. [Manufacturer identifies reference 7439](https://www.atosmedical.us/product/provox-trutone-emote-electrolarynx) without a public price. Request quote. |
| Servox Digital XL | Corrected manufacturer to Servona GmbH using [FDA/NLM record](https://accessgudid.nlm.nih.gov/devices/04040823006502). Manufacturer MSRP unverified. [Retailer](https://www.vitalitymedical.com/servox-digital-xl-electronic-speech-device.html) lists $1,201.03 list/$1,080.93 sale; these are retailer offers. Confirm model 37575 and kit contents. |
| Amazon Echo | Exact model/generation, MSRP. Do not choose a Dot, Show or other Echo variant on the name alone. |
| Dot Pad X | The catalog offers model DPA320X. Confirm MSRP separately. [Manufacturer product page](https://www.dotincorp.com/en/product/dotpadx). |
| Tobii Dynavox TD I-Series | Exact TD I-13 or TD I-16 configuration, quote/MSRP. [Manufacturer family page](https://us.tobiidynavox.com/pages/td-i-series). Existing draft status is retained. |
| HomeAware Home Alerting System | Filled manufacturer as Sonic Alert from its [HomeAware catalog](https://www.sonicalert.com/home-aware-signaling/homeaware). Exact kit/generation and MSRP remain unresolved. |
| Bellman & Symfon Visit | Exact transmitter/receiver bundle and MSRP; Visit is a system family, not a specified kit. |
| Tap-It Assistive Technology System | Confirmed manufacturer, exact intended system/model, MSRP. The [TAPit touchscreen brochure](https://assets.touchboards.com/assets/1/26/TAPit-Product-Brochure.pdf) and [JAN listing](https://askjan.org/products/TAP-it.cfm) are leads. Do not substitute the unrelated SquareGlow Tap It vibrating alert. |
| LogicKeyboard Large-Print Keyboard | LogicKeyboard confirmed by the user. Exact model, OS/layout, key contrast/backlighting and MSRP remain unselected. |
| TeliTalk Kit | Atos Medical confirmed by the user as Griffin's acquirer. Exact kit contents/model and MSRP remain unresolved. [FDA/NLM](https://accessgudid.nlm.nih.gov/devices/00813124010332) retains Griffin Laboratories for the K5200BT electrolarynx, while the [Kansas equipment list](https://atk.ku.edu/kansas-telecommunications-access-program) describes an EMOTE/holder/Panasonic phone bundle. Neither establishes the intended complete kit. |
| Wheelchair-Compatible Device Mount | Rehadapt confirmed from the user's screenshot. Exact model, chair clamp/device interface and MSRP remain unresolved. |
| Adjustable Tablet Mount | ModularHose confirmed from the user's screenshot; manufacturer/company Oak Hill Brands Corp. Exact holder/arm/clamp, tablet fit and MSRP remain unresolved. |
| Flexible Smartphone Mount | ModularHose confirmed from the user's screenshot; manufacturer/company Oak Hill Brands Corp. Exact holder/arm/clamp, phone fit and MSRP remain unresolved. |
| JAWS | Edition, license term and SMA. [Manufacturer store](https://store.vispero.com/collections/jaws) lists Home perpetual plus SMA at $1,572 and Professional plus SMA at $2,316.50, with different subscription prices. No edition is selected in the seed. |
| ZoomText | Edition, license term and SMA. [Manufacturer store](https://store.vispero.com/collections/zoomtext) lists Magnifier perpetual plus SMA at $905 and Magnifier/Reader plus SMA at $1,259, with different subscription prices. No edition is selected in the seed. |
| Tatum Robotics Tatum1 | No public fixed MSRP found; [manufacturer order request](https://tatumrobotics.com/pages/tatum1). Obtain quote and lead time. |
| nWise myMMX db | License/service-provider configuration and public MSRP; [manufacturer](https://nwise.se/solutions/deafblind-telecommunication/). Obtain provider quote. |

Tap-It is the remaining unresolved manufacturer. The Windows laptop manufacturer
is intentionally unspecified. The nine empty model-number entries are Samsung
Galaxy Tab, Windows laptop, Tap-It, LogicKeyboard Large-Print Keyboard, TeliTalk
Kit, the three mount families and Amazon Echo. HomeAware has a family name in its
model field but still needs an exact kit; the other family/bundle gaps above
likewise require more than a nonblank model field.

Optional content is also incomplete: 42 retained original entries lack a
dedicated `documentation_url` and description. Easy Flex Stylus, the six earlier
additions, two MacBook Air models, two new telephone products and Moshi strap have both. Price-source
links in seed comments are research provenance, not a claim that manuals or
training resources have been attached. Existing classifications, eligibility
groups are retained. BlindShell Beep and Easy Flex Stylus are confirmed models
in newly initialized catalogs. Samsung Galaxy Tab, LogicKeyboard and TeliTalk
remain drafts until exact models/configurations are selected.

## Manufacturer selections and remaining choices

The user confirmed Atos Medical for TeliTalk, LogicKeyboard for large-print
keyboards, Enabling Devices Easy Flex Stylus and the Samsung Galaxy Tab family.
Windows laptops intentionally remain generic. The user's screenshots confirmed Rehadapt for the
wheelchair mount and ModularHose for tablet/phone mounts; those three manufacturer
fields are now filled, while exact models and prices remain unconfirmed drafts.
The user selected Apple MacBook Air 13-inch and 15-inch for the MacBook entry;
the Windows laptop placeholder remains separate.

| Seed entry | Sources / closest match | Current disposition |
| --- | --- | --- |
| Samsung Galaxy Tab | [Samsung tablet comparison](https://www.samsung.com/us/tablets/compare/). | Manufacturer/family confirmed by the user; exact model/configuration remains a draft with no price. |
| Windows laptop | Generic Windows computer entry. | Intentionally no manufacturer, fixed model or MSRP; the program does not consistently supply one brand. |
| Tap-It Assistive Technology System | Historical TAPit by SmartEd Services/TeachSmart; later Stampede/Exertis branding. [WSU's contemporary account](https://archive.news.wsu.edu/news/2012/05/09/interactive-tech-excites-special-ed-students-teacher/) identifies SmartEd; [JAN](https://askjan.org/products/TAP-it.cfm) links TeachSmart. | SmartEd Services/TeachSmart is the closest historical attribution, with medium confidence until generation is known. TAPit is a large interactive touchscreen learning station. Confirm that this is the intended device; it is distinct from SquareGlow Tap It. |
| LogicKeyboard Large-Print Keyboard | [LogicKeyboard NERO Large Print](https://logickeyboard.com/shop/large-print-black-2983p.html) remains one possible model. | Manufacturer confirmed by the user. Select exact model, Mac/Windows compatibility, layout, contrast and backlighting before pricing. |
| TeliTalk Kit | [FDA/NLM](https://accessgudid.nlm.nih.gov/devices/00813124010332) identifies the historical Griffin labeler; a [Florida PSC filing](https://www.floridapsc.com/library/filings/2020/02780-2020/02780-2020.pdf) documents Atos's acquisition. | Manufacturer is Atos Medical, confirmed by the user. Exact bundle still needs selection; Panasonic can make the included phone and Teltex can supply the kit. |
| Enabling Devices Easy Flex Stylus | [Manufacturer item 9079](https://enablingdevices.com/product/easy-flex-stylus/). | Exact model selected by the user and confirmed in the seed, with $80.95 manufacturer direct reference price. |

For the now-confirmed mount brands, [ModularHose #110711](https://www.modularhose.com/tablet-holder-8-inch-arm-spring-clamp)
and [#110643](https://www.modularhose.com/phone-holder-24-inch-arm-mini-clamp) remain
possible tablet/phone configurations, not selected SKUs. The [Rehadapt wheelchair
mount family](https://rehadapt.com/solutions/wheelchair-mounts/standard/) likewise
requires a device/chair-specific configuration. No particular pictured model
or public price has been inferred from the broad category screenshots.

[ModularHose identifies itself as a division of Oak Hill Brands Corp.](https://www.modularhose.com/corporate)
For TAPit, later [Exertis private-label branding](https://av.technology/industry/exertis-australian-play)
means a historical SmartEd attribution should not be presented as a verified
current manufacturer for every generation.
