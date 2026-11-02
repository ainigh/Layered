# A map built to put the canvas and both arrange buttons to the test.
# It has a hub with many single branches (a ring), deep branches with long names and notes,
# every kind of node, the model's three kinds of card, links of every sort, cross-links
# between branches, several separate trees, and nodes linked to nothing.

# The launch: one hub, many single branches
| launch @kind event @date 2026-12-01
| launch - needs | press kit @kind thing
| launch - needs | landing page @kind thing
| launch - needs | pricing page @kind thing
| launch - needs | demo video @kind thing
| launch - needs | support docs @kind thing
| launch - needs | beta feedback @kind idea
| launch - needs | legal review @kind action
| launch - needs | security audit @kind action
| launch - needs | partner emails @kind action
| launch - needs | social posts @kind action
| launch - needs | launch party @kind event @date 2026-12-02
| launch - needs | status page @kind thing

# The team: a deep tree with long names, notes and labels
| maya @kind person @role product lead
| maya - leads | product team @kind thing
| product team - owns | onboarding flow redesign for new accounts @kind thing @todo ship by november
| product team - owns | billing @kind thing
| billing - depends on | payments provider integration @kind thing @src world
| billing - has | invoices @kind thing
| billing - has | refunds @kind thing @todo write the policy
| invoices - are sent by | email service @kind thing
| refunds - are approved by | finance team @kind thing
| product team - owns | analytics @kind thing
| analytics - tracks | activation rate @kind idea @goal above 40 percent
| analytics - tracks | weekly active teams @kind idea
| analytics - feeds | quarterly board report @kind thing @date 2027-01-15
| maya - works with | leo @kind person @role engineering
| leo - leads | platform team @kind thing
| platform team - runs | api gateway @kind thing
| platform team - runs | job queue @kind thing
| platform team - fixes | urgent bug in session handling @kind action @todo before launch
| api gateway - is deployed to | eu region @kind place
| api gateway - is deployed to | us region @kind place
| job queue - runs on | worker cluster @kind place
| leo - pairs with | ana @kind person @role design
| ana - designs | design system @kind thing
| design system - has | color tokens @kind thing
| design system - has | type scale @kind thing
| design system - has | icon set @kind thing

# The model's extras: world knowledge, a guess and advice
| payments provider integration - usually takes | six to eight weeks @src world
| launch - might slip to | january @src guess @kind event
| maya - should book | a launch rehearsal the week before @src advice @kind action
| security audit - is often run by | an outside firm @src world @kind thing

# Every sort of link
| maya - reports to | sam @kind person @role ceo
| sam - approves | pricing page
| maya - meets weekly - | leo
| ana - reviews | landing page
| landing page - shows | demo video
| leo - owns | status page
| security audit - covers | api gateway
| beta feedback - shapes | onboarding flow redesign for new accounts
| sam - presents at | launch party
| demo video - and | press kit - and | social posts
| support docs - | design system
| partner emails - go to | partners @kind person
| partners - send feedback to - | maya

# Separate small trees
| office move @kind event @date 2027-02
| office move - to | new office in lisbon @kind place
| office move - needs | movers @kind action
| office move - needs | new desks @kind thing
| office move - needs | network setup @kind action @status done
| hiring plan @kind idea
| hiring plan - adds | two engineers @kind person
| hiring plan - adds | one designer @kind person
| hiring plan - adds | support lead @kind person
| reading list @kind thing
| reading list - has | crossing the chasm @kind thing
| reading list - has | the mom test @kind thing

# Linked to nothing
| open questions @kind idea
| parking lot @kind thing
| retro notes @kind thing @date 2026-12-10
