# REST API lab E2E

Minimal manual test plan: [RA-minimal-functional-testplan.md](./RA-minimal-functional-testplan.md) (P0–P2, v2 + v3 Swagger, Jira/GitHub regression map).

| Script | Ticket | What it checks |
|--------|--------|----------------|
| `P0\RA-01-NCP7372-RegistryCoreEndpoint.ps1` | NCP-7372 | HKLM `ServerAddress` → Gateway connect log + `api/v2/IsConnected` (single machine, Core local) |
| `P1\RA-7384-RestApiTokenExpiration.ps1` | NCP-7384 | WMC `Rest_Api_Keys` + appsettings `AuthorizationTokenExpiration` accept/reject on `api/v2/IsConnected` |

## Run

```powershell
cd C:\Work\ResecTech\Resec.LabTests
.\RestApi\P1\RA-7384-RestApiTokenExpiration.ps1

# RA-01 only (NCP-7372 HKLM ServerAddress) — elevated:
.\RestApi\P0\RA-01-NCP7372-RegistryCoreEndpoint.ps1
```

Set `RESEC_RESTAPI_EXE_LOCATION` to your built `Resec.Agent.RestAPI.exe`. Core must be up (`EnableDebugInterface`); the test can auto-start Core unless you pass `-SkipAutoStartCore`.

By default the test **pushpolicystate** → **importpolicies** (policy `RA-01-rest-api-lab`, rule `agent_type` = `rest_api`) → **agentcommblockon/off**, then restores via **poppolicystate** in `finally`. Pass `-SkipCorePolicySetup` if Core already has a matching REST API policy.

**RA-01 only:** requires elevation (HKLM `ServerAddress`). Optional env `RESTAPI_E2E_SERVER_ADDRESS` overrides default `COMPUTERNAME`.

Default waits (RA-7384): Core ready **120s**, listen/**IsConnected** **45s**. Cold Core auto-start: `-CoreReadyTimeoutSec 180`.