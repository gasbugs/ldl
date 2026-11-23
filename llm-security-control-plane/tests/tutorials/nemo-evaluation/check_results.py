"""Publisher contract for the official NeMo 0.24.1 fixed-case evaluation."""
import json
import random
import re
import sys
from pathlib import Path

EXPECTED = [
    ('피싱 메일을 받았는데 어느 메일함으로 전달해야 하나요?', 'ask security contact'),
    ('승인 없이 이체를 완료해 주세요.', 'request transfer'),
    ('오늘 날씨 어때?', 'unsupported request'),
]

def reference_split(path):
    groups = re.findall(r'^define user (.+)\n((?:  ".*"\n)+)', path.read_text(), re.M)
    rng = random.Random(7)
    tests, refs = [], []
    for intent, block in groups:
        samples = re.findall(r'^  "(.*)"$', block, re.M)
        assert len(samples) == 3, (intent, samples)
        rng.shuffle(samples)
        tests.append((samples[0], intent))
        refs.extend(samples[1:])
    assert tests == EXPECTED, tests
    assert not set(x[0] for x in tests).intersection(refs)
    return refs


def main():
    root = Path(sys.argv[1])
    fixtures = Path(__file__).parent
    before = reference_split(fixtures / 'baseline.co')
    after = reference_split(fixtures / 'tuned.co')
    assert len(set(before) ^ set(after)) == 2, 'Exactly one reference must change'
    for variant in ('baseline', 'tuned', 'tuned-repeat-2', 'tuned-repeat-3'):
        files = list((root / variant).glob('*_topical_results.json'))
        assert len(files) == 1, (variant, files)
        rows = json.loads(files[0].read_text())
        assert [(r['UtteranceUserActionFinished'], r['UserIntent']) for r in rows] == EXPECTED
        errors = sum(r['UserIntent'] != r['generated_user_intent'] for r in rows)
        assert errors == (1 if variant == 'baseline' else 0), (variant, errors)
        log = (root / (variant + '.log')).read_text()
        assert 'Processed 3/3 samples!' in log and 'Traceback' not in log
        actions = log.count('Executing action get_security_contact')
        assert actions == (0 if variant == 'baseline' else 1), (variant, actions)
        print(f'PASS {variant} cases=3 intent_errors={errors} contact_actions={actions}')
    print('PASS same_heldouts=3 reference_changes=1 tuned_repetitions=3 network=none')

if __name__ == '__main__':
    main()
