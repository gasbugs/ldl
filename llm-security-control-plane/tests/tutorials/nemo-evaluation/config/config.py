from nemoguardrails.actions import action

@action(is_system_action=True)
async def get_security_contact() -> str:
    return "보안팀 연락처: security@example.com"

def init(app) -> None:
    app.register_action(get_security_contact, "get_security_contact")
