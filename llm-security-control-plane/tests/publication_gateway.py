"""Run the published Gateway with one local Converse response and no AWS traffic."""
from botocore.stub import Stubber
import uvicorn
import server

stubber = Stubber(server.BEDROCK)
stubber.add_response(
    "converse",
    {
        "output": {"message": {"role": "assistant", "content": [{"text": "OK"}]}},
        "stopReason": "end_turn",
        "usage": {"inputTokens": 1, "outputTokens": 1, "totalTokens": 2},
        "metrics": {"latencyMs": 1},
    },
)
stubber.activate()
uvicorn.run(server.app, host="0.0.0.0", port=8080, log_level="warning")
