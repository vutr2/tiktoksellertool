"""Run approved settlement tests in a disposable, socket-only PostgreSQL cluster.

Never reads .env or connects to the developer's existing database.
"""
import concurrent.futures
import getpass
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)


def quoted(value):
    return "'" + str(value).replace("'", "''") + "'"


def jsonsql(value):
    return quoted(json.dumps(value)) + "::jsonb"


def main():
    for binary in ["initdb", "pg_ctl", "psql"]:
        if not shutil.which(binary):
            raise RuntimeError(f"{binary} is required for local transaction tests")
    with tempfile.TemporaryDirectory(prefix="listingforge-postgres-") as directory:
        root = Path(directory)
        data = root / "data"
        socket = root / "socket"
        socket.mkdir()
        run("initdb", "-D", str(data), "-A", "trust", "--no-locale", "-E", "UTF8")
        # No TCP listener. A unique filesystem socket isolates parallel runs.
        run("pg_ctl", "-D", str(data), "-l", str(root / "postgres.log"), "-o",
            f"-k {socket} -c listen_addresses='' -p 65432", "-w", "start")
        try:
            def sql(statement, fails=False):
                result = subprocess.run(["psql", "-X", "-h", str(socket), "-p", "65432", "-U",
                    getpass.getuser(), "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-Atq"],
                    input=statement, capture_output=True, text=True)
                if fails:
                    assert result.returncode != 0, "Expected transaction failure"
                    return result.stderr
                if result.returncode:
                    raise RuntimeError(result.stderr)
                return result.stdout.strip()

            sql("create role anon; create role authenticated; create role service_role bypassrls;")
            for migration in sorted((ROOT / "supabase/migrations").glob("*.sql")):
                sql(migration.read_text())

            def account(balance=10):
                user, org, product = [str(uuid.uuid4()) for _ in range(3)]
                sql(f"insert into users(id) values('{user}'); insert into organizations(id,owner_user_id,name) "
                    f"values('{org}','{user}','Test'); insert into products(id,org_id,name) values('{product}','{org}','Test'); "
                    f"insert into credit_ledger(org_id,delta,reason,balance_after) values('{org}',{balance},'test.grant',{balance});")
                return user, org, product

            def begin(org, product, request=None, cost=6, key="same"):
                request = request or str(uuid.uuid4())
                result = sql(f"select begin_generation('{request}','{org}','{product}',{quoted(key)},'{{}}',{cost});")
                return request, json.loads(result)

            def completion(request, lease, charge=6, asset_type="title"):
                assets = [{"type": asset_type, "marketplace": "amazon", "content": "Test title",
                           "status": "warn", "violations": [{"message": "Review this claim"}]}]
                usages = [{"provider": "anthropic", "model": "test", "creditsCharged": charge,
                           "costUSD": None, "latencyMs": 10, "traceId": None}]
                return f"select complete_generation('{request}','{lease}',{jsonsql(assets)},{jsonsql(usages)},'{{}}',{charge});"

            user, org, product = account()
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(begin, org, product) for _ in range(2)]
                results = [future.result() for future in futures]
            assert sorted(result["status"] for _, result in results) == ["insufficient", "started"]
            request, reservation = next(item for item in results if item[1]["status"] == "started")
            assert begin(org, product, request)[1]["status"] == "running"
            assert begin(org, product, request, key="changed")[1]["status"] == "conflict"
            assert sql(f"select sum(delta) from credit_ledger where org_id='{org}'") == "10"
            print("PASS: concurrent reservations, immutable retry and no debit before output")

            # Force failure after asset insertion. No partial output or debit survives.
            sql("create function test_fail_usage() returns trigger language plpgsql as $$begin raise exception 'injected'; end$$; "
                "create trigger test_fail_usage before insert on generations for each row execute function test_fail_usage();")
            statement = completion(request, reservation["leaseToken"])
            sql(statement, fails=True)
            assert sql(f"select count(*) from assets where product_id='{product}'") == "0"
            assert sql(f"select sum(delta) from credit_ledger where org_id='{org}'") == "10"
            sql("drop trigger test_fail_usage on generations; drop function test_fail_usage();")
            first = json.loads(sql(statement))
            assert first["creditsCharged"] == 6 and first["balanceAfter"] == 4
            second = json.loads(sql(statement))
            assert first == second
            assert begin(org, product, request)[1]["result"] == first
            assert sql(f"select count(*) from credit_ledger where org_id='{org}' and delta<0") == "1"
            assert sql(f"select actual_cost_usd is null from generations where org_id='{org}'") == "t"
            print("PASS: rollback after asset insert; one settlement and stable asset IDs on replay")

            _, org2, product2 = account()
            request2, old = begin(org2, product2)
            sql(f"update generation_requests set lease_expires_at=now()-interval '1 minute' where id='{request2}'")
            _, new = begin(org2, product2, request2)
            assert old["leaseToken"] != new["leaseToken"]
            sql(completion(request2, old["leaseToken"]), fails=True)
            sql(f"select fail_generation('{request2}','{old['leaseToken']}')")
            assert sql(f"select status from generation_requests where id='{request2}'") == "running"
            sql(f"select fail_generation('{request2}','{new['leaseToken']}')")
            assert sql(f"select sum(delta) from credit_ledger where org_id='{org2}'") == "10"
            print("PASS: expired workers cannot settle or release a newer lease")

            user3, org3, product3 = account()
            request3, reserved3 = begin(org3, product3)
            sql(f"select begin_account_deletion('{user3}')")
            sql(completion(request3, reserved3["leaseToken"]), fails=True)
            assert begin(org3, product3)[1]["status"] == "unavailable"
            assert sql(f"select count(*) from assets where product_id='{product3}'") == "0"
            print("PASS: deletion blocks subsequent settlement and new reservations")

            # StoreKit fixtures enter only the server-only verified-transaction RPC.
            # No Apple account or production database is contacted.
            def purchase(user, kind="plan", amount=400, transaction=None):
                transaction = transaction or str(uuid.uuid4())
                return {"transactionId": transaction, "originalTransactionId": transaction,
                    "productId": "starter_monthly" if kind != "topup" else "topup_300",
                    "appAccountToken": user, "purchaseDate": "2026-01-01T00:00:00Z",
                    "expiresDate": None if kind == "topup" else "2099-02-01T00:00:00Z",
                    "revocationDate": None, "environment": "Sandbox", "signedDate": 100,
                    "tier": None if kind == "topup" else "starter", "creditsPerMonth": amount,
                    "payloadHash": "test", "schedule": [{"start": "2026-01-01T00:00:00Z",
                        "end": None if kind == "topup" else "2099-02-01T00:00:00Z",
                        "amount": amount, "kind": kind}]}

            def apply(org, record, now="2026-09-14T00:00:00Z"):
                return json.loads(sql(f"select apply_verified_apple_transaction('{org}',{jsonsql(record)},null,{quoted(now)});"))

            buyer, wallet, item = account(0)
            plan = purchase(buyer)
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                replies = list(pool.map(lambda _: apply(wallet, plan), range(2)))
            assert all(reply["balance"] == 400 for reply in replies)
            topup = purchase(buyer, "topup", 300)
            assert apply(wallet, topup)["balance"] == 700
            req, lease = begin(wallet, item, cost=6)
            sql(completion(req, lease["leaseToken"]))
            assert sql(f"select g.kind from credit_allocations a join credit_grants g on g.id=a.grant_id where g.org_id='{wallet}'") == "plan"
            assert apply(wallet, plan)["balance"] == 694
            plan["revocationDate"] = "2026-09-14T00:00:00Z"
            plan["signedDate"] = 200
            assert apply(wallet, plan)["balance"] == 294
            assert apply(wallet, plan)["balance"] == 294
            topup["revocationDate"] = "2026-09-14T00:00:00Z"
            assert apply(wallet, topup)["balance"] == -6
            restored = dict(topup, revocationDate=None, signedDate=300)
            event = {"id": str(uuid.uuid4()), "type": "REFUND_REVERSED"}
            statement = f"select apply_verified_apple_transaction('{wallet}',{jsonsql(restored)},{jsonsql(event)},'2026-09-14');"
            assert json.loads(sql(statement))["balance"] == 294
            assert json.loads(sql(statement))["balance"] == 294
            # An older refund notification must not revoke the restored purchase again.
            assert apply(wallet, topup)["balance"] == 294
            print("PASS: concurrent purchase replay, plan-first spending and idempotent refunds with negative balance")

            trial_user, trial_org, _ = account(0)
            assert apply(trial_org, purchase(trial_user, "trial", 100))["balance"] == 100
            assert apply(trial_org, purchase(trial_user, "trial", 100))["balance"] == 100
            sql(f"update credit_ledger set delta=10000 where org_id='{trial_org}'", fails=True)
            sql(f"delete from credit_ledger where org_id='{trial_org}'", fails=True)
            print("PASS: trial credits are granted only once per account")

            legacy_user, legacy_org, legacy_product = account(100)
            assert apply(legacy_org, purchase(legacy_user))["balance"] == 500
            legacy_request, legacy_lease = begin(legacy_org, legacy_product, cost=406)
            assert json.loads(sql(completion(legacy_request, legacy_lease["leaseToken"], charge=406)))["balanceAfter"] == 94
            print("PASS: pre-StoreKit credits remain spendable after the first Apple purchase")

            other_user, other_org, _ = account(0)
            stolen = dict(plan, appAccountToken=other_user)
            sql(f"select apply_verified_apple_transaction('{other_org}',{jsonsql(stolen)})", fails=True)
            deleted_user, deleted_org, _ = account(0)
            paid = purchase(deleted_user, "topup", 300)
            assert apply(deleted_org, paid)["balance"] == 300
            sql(f"select begin_account_deletion('{deleted_user}')")
            assert apply(deleted_org, purchase(deleted_user, "topup", 300))["balance"] == 300
            paid["revocationDate"] = "2026-09-14T00:00:00Z"
            paid["signedDate"] = 200
            assert apply(deleted_org, paid)["balance"] == 0
            print("PASS: cross-account replay blocked; deleted accounts receive refunds but no new grants")

            annual_user, annual_org, _ = account(0)
            annual = purchase(annual_user)
            annual["schedule"] = [
                {"start": "2026-01-01T00:00:00Z", "end": "2026-02-01T00:00:00Z", "amount": 400, "kind": "plan"},
                {"start": "2026-02-01T00:00:00Z", "end": "2026-03-01T00:00:00Z", "amount": 400, "kind": "plan"},
                {"start": "2026-03-01T00:00:00Z", "end": "2026-04-01T00:00:00Z", "amount": 400, "kind": "plan"}]
            assert apply(annual_org, annual, "2026-01-15T00:00:00Z")["balance"] == 400
            assert apply(annual_org, purchase(annual_user, "topup", 300), "2026-01-15T00:00:00Z")["balance"] == 700
            # Returning in March must grant February too, without advancing future months.
            assert apply(annual_org, annual, "2026-03-15T00:00:00Z")["balance"] == 1500
            assert sql(f"select count(*) from credit_grants where org_id='{annual_org}' and kind='plan'") == "3"
            assert apply(annual_org, annual, "2026-04-15T00:00:00Z")["balance"] == 1500
            assert sql(f"select count(*) from credit_ledger where org_id='{annual_org}' and reason='subscription.expiry'") == "0"
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                replies = list(pool.map(lambda _: apply(annual_org, annual, "2026-04-15T00:00:00Z"), range(2)))
            assert all(reply["balance"] == 1500 for reply in replies)

            # First reconciliation after the subscription ends still delivers every paid period.
            late_user, late_org, _ = account(0)
            late = dict(annual, transactionId=str(uuid.uuid4()), originalTransactionId=str(uuid.uuid4()),
                        appAccountToken=late_user, expiresDate="2026-04-01T00:00:00Z")
            assert apply(late_org, late, "2026-04-15T00:00:00Z")["balance"] == 1200
            assert sql(f"select status from subscriptions where org_id='{late_org}'") == "expired"
            late["revocationDate"] = "2026-04-16T00:00:00Z"
            late["signedDate"] = 200
            assert apply(late_org, late, "2026-04-16T00:00:00Z")["balance"] == 0
            assert apply(late_org, late, "2026-05-16T00:00:00Z")["balance"] == 0

            # A purchase refunded before reconciliation never creates catch-up credits.
            refunded_user, refunded_org, _ = account(0)
            refunded = dict(late, transactionId=str(uuid.uuid4()), originalTransactionId=str(uuid.uuid4()),
                            appAccountToken=refunded_user)
            assert apply(refunded_org, refunded, "2026-05-16T00:00:00Z")["balance"] == 0
            assert sql(f"select count(*) from credit_grants where org_id='{refunded_org}'") == "0"

            # Free trials retain their deadline and cannot be claimed retroactively.
            expired_user, expired_org, _ = account(0)
            expired_trial = purchase(expired_user, "trial", 100)
            expired_trial["expiresDate"] = "2026-01-08T00:00:00Z"
            expired_trial["schedule"][0]["end"] = "2026-01-08T00:00:00Z"
            assert apply(expired_org, expired_trial, "2026-02-01T00:00:00Z")["balance"] == 0
            print("PASS: missed paid periods are recovered exactly once, including after expiry; refunds and trial deadlines remain enforced")

            for signature in ["begin_generation(uuid,uuid,uuid,text,jsonb,integer)",
                              "complete_generation(uuid,uuid,jsonb,jsonb,jsonb,integer)",
                              "fail_generation(uuid,uuid)", "begin_account_deletion(uuid)",
                              "apply_verified_apple_transaction(uuid,jsonb,jsonb,timestamptz)",
                              "reconcile_credit_periods(uuid,timestamptz)"]:
                for role in ["anon", "authenticated"]:
                    assert sql(f"select has_function_privilege('{role}','{signature}','execute')") == "f"
                assert sql(f"select has_function_privilege('service_role','{signature}','execute')") == "t"
            print("PASS: settlement/deletion functions are restricted to the server role")
        finally:
            run("pg_ctl", "-D", str(data), "-m", "fast", "-w", "stop")


if __name__ == "__main__":
    main()
