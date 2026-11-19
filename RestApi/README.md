# REST API lab E2E

Minimal manual test plan: [RA-minimal-functional-testplan.md](./RA-minimal-functional-testplan.md) (P0–P2, v2 + v3 Swagger, Jira/GitHub regression map).

| Script | Ticket | What it checks |
|--------|--------|----------------|
| `P0\RA-01-NCP7372-RegistryCoreEndpoint.ps1` | NCP-7372 | HKLM `ServerAddress` → Gateway connect log + `api/v2/IsConnected` (single machine, Core local) |

## Run

```powershell
# Elevated PowerShell (HKLM registry)
cd C:\Work\ResecTech\Resec.LabTests
.\RestApi\P0\RA-01-NCP7372-RegistryCoreEndpoint.ps1
```

Set `RESEC_RESTAPI_EXE_LOCATION` to your built `Resec.Agent.RestAPI.exe`. Core must be up (`EnableDebugInterface`); the test can auto-start Core unless you pass `-SkipAutoStartCore`.

By default the test **pushpolicystate** → **importpolicies** (policy `RA-01-rest-api-lab`, rule `agent_type` = `rest_api`) → **agentcommblockon/off**, then restores via **poppolicystate** in `finally`. Pass `-SkipCorePolicySetup` if Core already has a matching REST API policy.

Optional: `RESTAPI_E2E_SERVER_ADDRESS` overrides the default `COMPUTERNAME` registry value.

Default waits: Core ready **120s**, connect log **45s**, `IsConnected` **90s** (Kestrel may bind after Gateway connect). Cold Core auto-start: `-CoreReadyTimeoutSec 180`.