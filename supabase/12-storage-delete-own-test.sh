#!/usr/bin/env bash
# WePark — supabase/12-storage-delete-own.sql scratch-Postgres test.
#
# Runs against a THROWAWAY local Postgres 16 (NOT Supabase, NOT production). Real migrations 01-06
# (incl. 02f's pin-evidence bucket + select/insert policies) on a Supabase-shaped stub, then 12 applied
# twice, then driven as the real `anon` / `authenticated` roles.
#
# WHAT THIS PROVES: the RLS policy logic on storage.objects — a user can DELETE only objects in the
# `pin-evidence` bucket whose first path segment equals their own auth.uid()::text; nobody else's, no
# other bucket's, nothing for anon; the case-sensitivity trap (uppercase prefix matches nothing);
# the policy set after apply (select/insert/delete); idempotent re-apply.
# WHAT IT CANNOT PROVE (stub): `storage.objects` here is a plain table. There is no Storage service,
# no S3 object, no protect_delete trigger, no real list/remove HTTP API, and `storage.objects` ownership
# (supabase_storage_admin) is not modeled — so "the SQL Editor role can create this policy" and "the
# Storage API remove call returns 200 and the file is gone" are NOT proven here. Those are Kevin's
# ceremony steps (docs/supabase-ceremony-10-11.md, Step 3 and Step 4).
#
# Usage:  PGHOST=/path/to/socketdir PGPORT=55432 PGUSER=postgres ./supabase/12-storage-delete-own-test.sh
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scratch/common.sh"

scratch_create_db t12
echo "== scratch DB $DB: migrations 01-06 applied; $(sql "$DB" 'show server_version')"

echo "== Test 0: policy state before 12, then clean apply + idempotent re-apply"
check "before 12: only select + insert policies (02f)" \
  "$(sql "$DB" "select string_agg(polname||':'||polcmd::text, ',' order by polname) from pg_policy where polrelid='storage.objects'::regclass and polname like 'pin_evidence_storage_%'")" \
  "pin_evidence_storage_insert_own:a,pin_evidence_storage_select_own:r"
check "apply 12" "$(apply_file 12-storage-delete-own.sql)" "ok"
check "re-apply 12 (idempotent)" "$(apply_file 12-storage-delete-own.sql)" "ok"
check "after 12: select + insert + delete, exactly one of each" \
  "$(sql "$DB" "select string_agg(polname||':'||polcmd::text, ',' order by polname) from pg_policy where polrelid='storage.objects'::regclass and polname like 'pin_evidence_storage_%'")" \
  "pin_evidence_storage_delete_own:d,pin_evidence_storage_insert_own:a,pin_evidence_storage_select_own:r"

A=$(new_user false); B=$(new_user false)
UP=$(printf '%s' "$A" | tr 'a-f' 'A-F')   # what Swift's UUID.uuidString would produce
sql "$DB" "
insert into storage.buckets (id, name, public) values ('other-bucket','other-bucket',false) on conflict do nothing;
insert into storage.objects (bucket_id, name) values
  ('pin-evidence', '$A/g1/a.jpg'), ('pin-evidence', '$A/g1/b.jpg'), ('pin-evidence', '$A/g2/c.jpg'),
  ('pin-evidence', '$B/g9/z.jpg'),
  ('pin-evidence', '$UP/g1/upper.jpg'),
  ('pin-evidence', 'loose-file.jpg'),
  ('other-bucket', '$A/g1/other.jpg');" >/dev/null
objs() { sql "$DB" "select count(*) from storage.objects where $1"; }
echo "== fixtures: A=$A B=$B; 3 objects under A/, 1 under B/, 1 uppercase-A prefix, 1 loose, 1 in another bucket"

echo "== Test 1: nobody but the owner, nothing outside the bucket"
out=$(sql_as "$DB" anon "" "delete from storage.objects where bucket_id='pin-evidence' returning name;")
check "anon (no JWT) deletes 0 rows" "$(printf '%s' "$out" | grep -c .)" "0"
out=$(sql_as "$DB" anon "$A" "delete from storage.objects where bucket_id='pin-evidence' returning name;")
check "anon role even with a forged sub claim for A deletes 0 rows (policy is TO authenticated)" "$(printf '%s' "$out" | grep -c .)" "0"
check "...and no object was removed" "$(objs "true")" "7"
out=$(sql_as "$DB" authenticated "$B" "delete from storage.objects where name like '$A/%' returning name;")
check "authenticated B deleting A's prefix deletes 0 rows" "$(printf '%s' "$out" | grep -c .)" "0"
out=$(sql_as "$DB" authenticated "$B" "delete from storage.objects returning name;")
check "B's unqualified delete-all removes only B's own single object" "$(printf '%s' "$out" | grep -c .)" "1"
check "...A's 3 objects intact" "$(objs "name like '$A/%' and bucket_id='pin-evidence'")" "3"
check "...B's object is the one that went" "$(objs "name like '$B/%'")" "0"

echo "== Test 2: the owner removes exactly their own files in the bucket (the iOS step-2 call)"
out=$(sql_as "$DB" authenticated "$A" "delete from storage.objects where bucket_id='pin-evidence' and name in ('$A/g1/a.jpg','$A/g1/b.jpg') returning name;")
check "A removes 2 named files (DELETE ... RETURNING works; needs select-own too)" "$(printf '%s' "$out" | grep -c .)" "2"
out=$(sql_as "$DB" authenticated "$A" "delete from storage.objects where name like '$A/%' returning name;")
check "A's sweep deletes the remaining pin-evidence file only (other-bucket copy not matched by policy)" "$(printf '%s' "$out" | grep -c .)" "1"
check "other-bucket object under A's prefix survives (policy is bucket-scoped)" "$(objs "bucket_id='other-bucket'")" "1"
check "no pin-evidence objects remain under A/" "$(objs "bucket_id='pin-evidence' and name like '$A/%'")" "0"
check "loose top-level file survives (no folder segment -> no match)" "$(objs "name='loose-file.jpg'")" "1"
out=$(sql_as "$DB" authenticated "$A" "delete from storage.objects where name = 'loose-file.jpg' returning name;")
check "A cannot delete the loose file either" "$(printf '%s' "$out" | grep -c .)" "0"

echo "== Test 3: the case trap, uppercase prefix (Swift UUID.uuidString) matches nothing"
out=$(sql_as "$DB" authenticated "$A" "delete from storage.objects where name like '$UP/%' returning name;")
check "A cannot delete an object whose prefix is the UPPERCASE uuid" "$(printf '%s' "$out" | grep -c .)" "0"
check "...it is still there (so iOS must list/remove with .lowercased() prefixes)" "$(objs "name like '$UP/%'")" "1"
out=$(sql_as "$DB" authenticated "$A" "insert into storage.objects (bucket_id, name) values ('pin-evidence', '$UP/g1/new.jpg');")
check_err "...and the EXISTING 02f insert policy rejects an uppercase-prefix upload too (PinEvidenceUploader.swift:201 concern)" "$out" 42501
out=$(sql_as "$DB" authenticated "$A" "insert into storage.objects (bucket_id, name) values ('pin-evidence', '$A/g3/new.jpg');")
check_ok "lowercase-prefix upload by A is accepted (control)" "$out"

echo "== Test 4: policy surface did not widen anything else"
out=$(sql_as "$DB" authenticated "$B" "update storage.objects set name = name || 'x' where name like '$A/%' returning name;")
check "no UPDATE policy: B cannot rename A's files (0 rows)" "$(printf '%s' "$out" | grep -c .)" "0"
out=$(sql_as "$DB" authenticated "$A" "update storage.objects set name = name || 'x' where name like '$A/%' returning name;")
check "no UPDATE policy: A cannot update their own either (0 rows)" "$(printf '%s' "$out" | grep -c .)" "0"
check "A still cannot SELECT B-prefixed rows (02f select-own unchanged)" "$(sql_as "$DB" authenticated "$A" "select count(*) from storage.objects where name like '$B/%';")" "0"

echo "== Test 5: the DELETE policy gates on its own (02f's select-own otherwise masks it)"
# Postgres applies the SELECT policy to the rows a DELETE ... WHERE can see, so with select-own in place the
# DELETE policy's own owner/bucket clauses are never the deciding factor. Temporarily widen SELECT to
# `using (true)` (scratch DB only) to prove the DELETE policy is independently correct, then restore.
sql "$DB" "
drop policy pin_evidence_storage_select_own on storage.objects;
create policy pin_evidence_storage_select_own on storage.objects for select using (true);
insert into storage.objects (bucket_id, name) values
  ('pin-evidence', '$A/t5/mine.jpg'), ('pin-evidence', '$B/t5/theirs.jpg'), ('other-bucket', '$A/t5/otherbucket.jpg');" >/dev/null
out=$(sql_as "$DB" authenticated "$A" "delete from storage.objects where name like '%/t5/%' returning name;")
check "with SELECT wide open, A still deletes ONLY their own pin-evidence object (owner + bucket clauses)" "$(printf '%s' "$out" | tr -d '\n')" "$A/t5/mine.jpg"
check "...B's object survived" "$(objs "name='$B/t5/theirs.jpg'")" "1"
check "...A's other-bucket object survived" "$(objs "name='$A/t5/otherbucket.jpg'")" "1"
out=$(sql_as "$DB" anon "" "delete from storage.objects where name like '%/t5/%' returning name;")
check "with SELECT wide open, anon still deletes nothing" "$(printf '%s' "$out" | grep -c .)" "0"
sql "$DB" "
drop policy pin_evidence_storage_select_own on storage.objects;
create policy pin_evidence_storage_select_own on storage.objects for select using (
  bucket_id = 'pin-evidence' and auth.uid() is not null and auth.uid()::text = (storage.foldername(name))[1]);" >/dev/null

finish
