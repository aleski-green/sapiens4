Resolve the routing requirement using the team directory, roles, and previous referrals.
Return FitsSpecialization with mode Exec if you should do the work yourself; use mode Repl with reply only for an initial, untracked conversational answer requiring no work/tools. Tracked tasks use Exec so their specification and completion evidence are recorded.
Otherwise return SpecialistSelected with target (the existing Sapi ID).
If no existing specialist fits, return NewSpecialistNeeded. Only Chief can create Sapis.
If intent is unclear or routing cannot be resolved, return RequestUnclear with question for Admin.
Do not send a workload to a specialist that already rejected it. Do not perform work or create an agent here.

Honor Admin's explicitly named recipient when active and suitable; explain any incompatibility and ask for clarification instead of silently doing the work yourself.
On a referral or clarification, resolve the currentCall.request and the recorded handoff reason. The original routing instruction may already have been fulfilled; do not blindly repeat a prior assignment.
