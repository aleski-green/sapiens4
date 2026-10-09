"""Conditional branches never weaken unconditional completion requirements."""
import unittest
from sapiens.corpora.host.delegation import validate_outcome
from sapiens.validation import APIError


class CompletionTest(unittest.TestCase):
    def response(self, satisfied, skipped=None, evidence=None):
        value = dict(status='Completed', satisfiedCriteria=satisfied, artifacts=[])
        if skipped is not None:
            value['notApplicableCriteria'] = skipped
        return dict(outcome=value, evidence=['Verified saved artifact.'] if evidence is None else evidence)

    def test_either_verified_branch_can_complete(self):
        criteria = ['Read the collection.', 'If a joke is found, save it.', 'If no joke is found, report that.', 'Leave Memo unchanged.']
        for chosen, unused in [(1, 2), (2, 1)]:
            with self.subTest(chosen=chosen):
                result = self.response([criteria[0], criteria[chosen], criteria[3]], {criteria[unused]: 'The opposite condition was verified.'})
                self.assertEqual(validate_outcome(result, criteria)['status'], 'Completed')

    def test_missing_applicable_requirement_or_evidence_still_fails(self):
        criteria = ['Save the file.', 'If nothing was found, report that.']
        for result in [self.response([], {criteria[1]: 'Found an item.'}),
                       self.response([criteria[0]], {criteria[1]: 'Found an item.'}, evidence=[])]:
            with self.assertRaisesRegex(ValueError, 'requires evidence'):
                validate_outcome(result, criteria)

    def test_only_known_explicit_conditions_with_reasons_can_be_skipped(self):
        criteria = ['Save the file.', 'If nothing was found, report that.']
        for skipped in [{criteria[0]: 'Not needed'}, {'If unknown, skip it.': 'Unknown'},
                        {criteria[1]: ''}, {criteria[1]: None}, []]:
            with self.subTest(skipped=skipped), self.assertRaises((ValueError, APIError)):
                validate_outcome(self.response([], skipped), criteria)
        with self.assertRaises((ValueError, APIError)):
            validate_outcome(self.response(criteria, {criteria[1]: 'Not applicable'}), criteria)

    def test_existing_outcomes_remain_valid(self):
        self.assertEqual(validate_outcome(self.response(['Save the file.']), ['Save the file.'])['status'], 'Completed')
        result = self.response([])
        result['outcome']['status'] = 'Unresolved'
        self.assertEqual(validate_outcome(result, ['Save the file.'])['status'], 'Unresolved')
