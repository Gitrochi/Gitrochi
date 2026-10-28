# Gitrochi repository reader and MCP

Gitrochi의 저장소 AI와 외부 MCP 클라이언트가 함께 사용하는 읽기 도구입니다. Node.js 22 이상과 시스템 Git이 필요하며 추가 패키지는 없습니다. Mac·Windows 앱에 `gitrochi-mcp.mjs`라는 리소스로 포함됩니다. 도구 위치는 앱의 설정 → 도구에서 지정합니다.

앱의 저장소 메뉴 → **MCP로 외부 AI 연결…**에서 현재 저장소 전용 설정을 복사하고 연결을 시험합니다. 이 설정을 사용할 AI 클라이언트의 MCP 서버 설정에 추가하세요. 앱은 클라이언트 설정 파일을 직접 변경하지 않습니다.

소스에서 직접 연결할 때의 구조:

```json
{
  "mcpServers": {
    "gitrochi": {
      "command": "node",
      "args": ["/absolute/path/to/server.mjs", "--repo", "/absolute/path/to/repository", "--git", "git"]
    }
  }
}
```

Windows 경로는 JSON 문자열에서 `C:/projects/example`처럼 슬래시를 사용하거나 역슬래시를 이스케이프합니다. gitch 사전 점검을 함께 제공하려면 `--gitch`에 스크립트 경로, `--bash`에 Bash 실행 파일 경로를 더합니다. 앱이 복사하는 설정에는 탐지한 경로가 들어 있습니다.

## 제공 도구

| 도구 | 범위 |
| --- | --- |
| `git_status` | 추적 파일과 브랜치 상태 |
| `git_log` | 최대 100개 커밋, 선택한 경로·시점 |
| `git_show` | 커밋 메시지·변경, 선택한 경로 |
| `git_diff` | 작업 파일·스테이지·두 커밋 비교 |
| `git_files` | 추적 파일 이름의 부분 일치 검색 |
| `read_file` | 추적 중인 일반 텍스트 파일, 현재 내용 또는 커밋 blob |
| `search_code` | 최대 100개 추적 파일에서 문자열 그대로 검색 |
| `gitch_preflight` | 계정 잠금·사전 점검 읽기 |
| `graph_context` | Bounded file graph context with a real snapshot ID, provenance, coverage and selected paths |

The app reader uses the same bundled gitch and static manifest-reading environment as the embedded graph workspace, so validated actions refer to the same snapshot. Graph context prioritizes selected files and their neighbors, excludes unsafe paths, and reports omitted nodes/edges. The provider-facing response remains valid bounded JSON; its coverage limits are separate from text truncation. Task prompt templates are saved per repository, while conversation/read activity remains in memory.

Git 쓰기, 임의 셸, 인증 설정, 네트워크 도구는 노출하지 않습니다. 연결 시 고른 저장소 밖으로 이동할 수 없고 경로·Git 디렉터리가 바뀌면 재연결을 요구합니다. 파일은 64 KB까지, 도구 응답은 18,000자까지이며 생략 여부를 제공합니다. 전체 diff는 비밀 경로를 제외한 최대 150개 파일입니다. 큰 결과·검색 제한 때문에 일부 근거를 읽지 못할 수 있습니다.

비밀 경로와 심볼릭 링크·바이너리 파일을 제외하고 흔한 토큰·비밀값 형식은 가립니다. 모든 비밀값을 알아낼 수 있는 것은 아닙니다. 외부 AI에 연결하면 클라이언트가 읽기 결과를 선택한 공급자에게 보낼 수 있으므로 해당 클라이언트의 전송 설정을 확인하세요. 저장소 안의 문서는 실행할 명령이 아닌 자료로 취급해야 합니다.

stdio JSON-RPC를 사용하며 MCP 2025-11-25, 2025-06-18, 2024-11-05 초기화를 지원합니다. 네트워크 포트를 열거나 로그 파일에 읽은 내용을 보관하지 않습니다. 앱 AI 대화와 읽기 기록은 현재 대화 메모리에만 보관합니다.

검사:

```sh
node --test tools/gitrochi-mcp/server.test.mjs
```

프로토콜 참고: [stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), [초기화](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle), [도구](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).
