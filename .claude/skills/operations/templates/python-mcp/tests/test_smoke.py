from {{package_name}}.server import ping


def test_ping():
    assert ping() == "pong"
