# WePark team (agents)

Kevin is founder and final decider. The orchestrator (main Claude session) dispatches agents and is the only one that commits, merges, uploads or touches prod, and only with Kevin's OK where required.

## Product and engineering
| Agent | Owns |
|---|---|
| `tech-lead` | Specs and architecture before code |
| `ios-engineer` | All code under `ios/` |
| `backend-data` | Supabase, tile pipeline, NYC data |
| `pwa-maintainer` | Web app and getwepark.com |
| `designer` | UI/UX review (Stoop design system) |
| `qa-verifier` | Independent QA, never the builder |

## Business (added 2026-11-27)
| Agent | Owns | Output folder |
|---|---|---|
| `product-manager` | Roadmap, prioritization, problem briefs, feedback themes | `docs/company/product/` |
| `growth-marketer` | Positioning, App Store listing, launch plans, content, referral | `docs/company/marketing/` |
| `community-support` | Reply drafts, saved replies, issue log, moderation policy, testers | `docs/company/support/` |
| `data-analyst` | Metrics, privacy-first analytics plan, reports, experiments | `docs/company/data/` |
| `partnerships` | Partner pipeline, car-services marketplace, deal memos | `docs/company/partnerships/` |
| `legal-compliance` | Privacy, App Store rules, terms, UGC, marketplace risk (not a lawyer) | `docs/company/legal/` |
| `finance-fundraising` | Costs, unit economics, pricing, fundraising readiness | `docs/company/finance/` |

All business agents draft only: they never post, send, sign up, spend, or touch prod.

## Back-burner ideas
- Car services marketplace (snow dig-out, wash, car moving): `docs/product/car-services-marketplace-concept.md`
