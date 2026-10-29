@turn 1 2026-10-28T14:02:33Z model extract text 1
# people
| ana @kind person @src text @text 1 s1
| sam @kind person @src text @text 1 s1
| kim @kind person @src text @text 1 s3
| reviewer @kind person @src text @text 1 s7
# places
| lisbon @kind place @src text @text 1 s1
| lab cluster @kind place @src text @text 1 s4
# work
| paper @kind thing @src text @text 1 s1
| abstract @kind thing @src text @text 1 s5
| related work @kind thing @src text @text 1 s6
| experiment @kind event @src text @text 1 s4
| workshop @kind event @src text @text 1 s3
| ana - met in @src text @text 1 s1 | lisbon
| sam - met in @src text @text 1 s1 | lisbon
| ana - plans @src text @text 1 s1 | paper
| sam - drafts @src text @text 1 s2 | paper
| ana - reviews @src text @text 1 s2 | paper
| paper @date 2026-11-03 @src text @text 1 s3
| kim - chairs @src text @text 1 s3 | workshop
| kim - sets deadline of @src text @text 1 s3 | paper
| experiment - runs on @src text @text 1 s4 | lab cluster
| kim - asked for @src text @text 1 s5 | abstract
| abstract @todo by friday @src text @text 1 s5
| paper - has @src text @text 1 s6 | related work
| ana - worries about @src text @text 1 s6 | related work
| sam - will email @src text @text 1 s7 | reviewer
@turn 2 2026-10-28T14:10:00Z model expand paper
| journal @src world
| paper - could target @src world | journal
| sam - should ask early @src advice | reviewer
| paper - cites @src guess | experiment
@turn 3 2026-10-28T14:12:00Z user confirm journal
| journal @src user
