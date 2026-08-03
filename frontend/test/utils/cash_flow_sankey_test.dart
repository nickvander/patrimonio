import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/cash_flow_sankey.dart';

/// Unit tests for the cash-flow Sankey's pure layer.
///
/// The headline contract is RECONCILIATION: what the diagram draws must add
/// up to the same income / spending figures the cash-flow tab's own
/// `MonthlyCashFlowCard` prints for the same period. A Sankey whose ribbons
/// don't sum to the node they leave is the exact class of lie this card would
/// otherwise be very good at telling.

const _labels = CashFlowSankeyLabels(
  income: 'Income',
  otherIncome: 'Other income',
  moneyIn: 'Money in',
  saved: 'Left over',
  invested: 'Invested',
  fromSavings: 'From savings',
  fromInvestments: 'From investments',
  uncategorized: 'Uncategorized',
  fxConversion: 'FX conversion',
);

/// Two months of trends, USD, exactly as `/dashboard/trends` returns them.
List<Map<String, dynamic>> _trends() => [
  {
    'month': '2026-06',
    'income': 5000.0,
    'spending': 3000.0,
    'invested': 500.0,
    'transferred': 0.0,
  },
  {
    'month': '2026-07',
    'income': 6000.0,
    'spending': 4000.0,
    'invested': 0.0,
    'transferred': 0.0,
  },
];

/// `/dashboard/spending-by-category` over the same window. Per month these
/// sum to the trend rows' `spending` — the endpoints share one SQL hygiene
/// fragment, so this is what the real pair looks like.
Map<String, dynamic> _categories() => {
  'months': ['2026-06', '2026-07'],
  'categories': [
    {
      'category': 'RENT_AND_UTILITIES',
      'total': 4000.0,
      'monthly': [
        {'month': '2026-06', 'amount': 2000.0},
        {'month': '2026-07', 'amount': 2000.0},
      ],
    },
    {
      'category': 'FOOD_AND_DRINK',
      'total': 3000.0,
      'monthly': [
        {'month': '2026-06', 'amount': 1000.0},
        {'month': '2026-07', 'amount': 2000.0},
      ],
    },
  ],
};

CashFlowSankeyData _build({
  List<Map<String, dynamic>>? trends,
  Map<String, dynamic>? categories,
  String? selectedMonthIso,
  bool aggregate = false,
  List<dynamic> transactions = const <dynamic>[],
  List<dynamic> fxTransfers = const <dynamic>[],
  double conversionFactor = 1.0,
  String targetCurrency = 'USD',
  double usdMxnRate = 18.0,
  int maxCategories = 8,
}) {
  return buildCashFlowSankey(
    trends: trends ?? _trends(),
    selectedMonthIso: selectedMonthIso,
    aggregate: aggregate,
    categoryData: categories ?? _categories(),
    transactions: transactions,
    fxTransfers: fxTransfers,
    conversionFactor: conversionFactor,
    targetCurrency: targetCurrency,
    usdMxnRate: usdMxnRate,
    labels: _labels,
    maxCategories: maxCategories,
  );
}

double _sumOut(SankeyDiagram d, String nodeId) => d.links
    .where((l) => l.source == nodeId)
    .fold<double>(0, (s, l) => s + l.value);

double _sumIn(SankeyDiagram d, String nodeId) => d.links
    .where((l) => l.target == nodeId)
    .fold<double>(0, (s, l) => s + l.value);

void main() {
  group('month selection mirrors MonthlyCashFlowCard', () {
    test('defaults to the latest month in the series', () {
      expect(
        sankeyMonthKeys(
          trends: _trends(),
          selectedMonthIso: null,
          aggregate: false,
        ),
        ['2026-07'],
      );
    });

    test('honours an explicit month (the "Last month" period)', () {
      expect(
        sankeyMonthKeys(
          trends: _trends(),
          selectedMonthIso: '2026-06',
          aggregate: false,
        ),
        ['2026-06'],
      );
    });

    test('an aggregated window sums every month returned', () {
      expect(
        sankeyMonthKeys(
          trends: _trends(),
          selectedMonthIso: null,
          aggregate: true,
        ),
        ['2026-06', '2026-07'],
      );
    });

    test('an unknown month falls back to the latest, never to nothing', () {
      expect(
        sankeyMonthKeys(
          trends: _trends(),
          selectedMonthIso: '2019-01',
          aggregate: false,
        ),
        ['2026-07'],
      );
    });
  });

  group('reconciliation with the cash-flow tab', () {
    test('single month: totals and every column match the trend row', () {
      final d = _build();

      // The figures the tab's summary card prints for the same month.
      expect(d.income, 6000.0);
      expect(d.spending, 4000.0);
      expect(d.invested, 0.0);
      expect(d.net, 2000.0);
      expect(d.monthKeys, ['2026-07']);

      // Conservation: sources == hub == destinations.
      expect(_sumIn(d.main, 'hub'), closeTo(6000.0, 1e-9));
      expect(_sumOut(d.main, 'hub'), closeTo(6000.0, 1e-9));
      expect(d.main.total, closeTo(6000.0, 1e-9));

      // And the spending half of that adds up to the trend row's spending.
      final spendBands = d.main.links
          .where((l) => l.source == 'hub' && l.target.startsWith('cat:'))
          .fold<double>(0, (s, l) => s + l.value);
      expect(spendBands, closeTo(d.spending, 1e-9));
    });

    test('aggregated window sums every month on both sides', () {
      final d = _build(aggregate: true);
      expect(d.income, 11000.0);
      expect(d.spending, 7000.0);
      expect(d.invested, 500.0);
      // 11000 in, 7000 spent, 500 into investments.
      expect(d.net, 3500.0);
      expect(_sumIn(d.main, 'hub'), closeTo(11000.0, 1e-9));
      expect(_sumOut(d.main, 'hub'), closeTo(11000.0, 1e-9));

      final invested = d.main.links.firstWhere(
        (l) => l.target == 'out:invested',
      );
      expect(invested.value, closeTo(500.0, 1e-9));
      final saved = d.main.links.firstWhere((l) => l.target == 'out:saved');
      expect(saved.value, closeTo(3500.0, 1e-9));
    });

    test('categories the breakdown misses become an Uncategorized flow', () {
      // Backend hands back only half the month's spending (e.g. `top` folded
      // nothing but a category was dropped). The residual must SHOW, not
      // silently shrink the river.
      final partial = {
        'months': ['2026-07'],
        'categories': [
          {
            'category': 'FOOD_AND_DRINK',
            'total': 1500.0,
            'monthly': [
              {'month': '2026-07', 'amount': 1500.0},
            ],
          },
        ],
      };
      final d = _build(categories: partial);
      expect(d.spending, closeTo(4000.0, 1e-9));
      final residual = d.main.links.firstWhere(
        (l) => l.target == 'cat:UNRECONCILED',
      );
      expect(residual.value, closeTo(2500.0, 1e-9));
      expect(d.main.nodeById('cat:UNRECONCILED')!.label, 'Uncategorized');
    });

    test('no breakdown at all degrades to one honest Uncategorized flow', () {
      final d = buildCashFlowSankey(
        trends: _trends(),
        selectedMonthIso: null,
        aggregate: false,
        categoryData: null,
        transactions: const <dynamic>[],
        fxTransfers: const <dynamic>[],
        conversionFactor: 1.0,
        targetCurrency: 'USD',
        usdMxnRate: 18.0,
        labels: _labels,
      );
      expect(d.spending, closeTo(4000.0, 1e-9));
      expect(
        d.main.links.firstWhere((l) => l.target == 'cat:UNRECONCILED').value,
        closeTo(4000.0, 1e-9),
      );
      expect(_sumOut(d.main, 'hub'), closeTo(6000.0, 1e-9));
    });

    test('a category tail past the cap folds into OTHER, never vanishes', () {
      final many = {
        'months': ['2026-07'],
        'categories': [
          for (var i = 0; i < 10; i++)
            {
              'category': 'CAT_$i',
              'total': 400.0,
              'monthly': [
                {'month': '2026-07', 'amount': 400.0},
              ],
            },
        ],
      };
      final d = _build(categories: many, maxCategories: 3);
      final catTotal = d.main.links
          .where((l) => l.target.startsWith('cat:'))
          .fold<double>(0, (s, l) => s + l.value);
      expect(catTotal, closeTo(4000.0, 1e-9));
      // 10 categories capped at 3 → 3 kept + one OTHER rollup.
      final catNodes = d.main.nodes.where((n) => n.id.startsWith('cat:'));
      expect(catNodes.length, 4);
      expect(
        d.main.links.firstWhere((l) => l.target == 'cat:OTHER').value,
        closeTo(2800.0, 1e-9),
      );
    });
  });

  group('deficit and divestment keep the river conservative', () {
    test('spending past income adds a From-savings inflow', () {
      final overspent = [
        {
          'month': '2026-07',
          'income': 1000.0,
          'spending': 2500.0,
          'invested': 0.0,
          'transferred': 0.0,
        },
      ];
      final cats = {
        'months': ['2026-07'],
        'categories': [
          {
            'category': 'FOOD_AND_DRINK',
            'total': 2500.0,
            'monthly': [
              {'month': '2026-07', 'amount': 2500.0},
            ],
          },
        ],
      };
      final d = _build(trends: overspent, categories: cats);
      expect(d.net, closeTo(-1500.0, 1e-9));
      final drawdown = d.main.links.firstWhere(
        (l) => l.source == 'src:drawdown',
      );
      expect(drawdown.value, closeTo(1500.0, 1e-9));
      expect(d.main.nodeById('src:drawdown')!.label, 'From savings');
      // Nothing is "left over" when the period ran a deficit.
      expect(d.main.nodeById('out:saved'), isNull);
      expect(_sumIn(d.main, 'hub'), closeTo(_sumOut(d.main, 'hub'), 1e-9));
    });

    test('net selling shows as a From-investments inflow', () {
      final divesting = [
        {
          'month': '2026-07',
          'income': 1000.0,
          'spending': 1500.0,
          'invested': -800.0,
          'transferred': 0.0,
        },
      ];
      final cats = {
        'months': ['2026-07'],
        'categories': [
          {
            'category': 'FOOD_AND_DRINK',
            'total': 1500.0,
            'monthly': [
              {'month': '2026-07', 'amount': 1500.0},
            ],
          },
        ],
      };
      final d = _build(trends: divesting, categories: cats);
      expect(
        d.main.links.firstWhere((l) => l.source == 'src:divest').value,
        closeTo(800.0, 1e-9),
      );
      // 1000 income + 800 out of investments − 1500 spent = 300 left.
      expect(d.net, closeTo(300.0, 1e-9));
      expect(_sumIn(d.main, 'hub'), closeTo(_sumOut(d.main, 'hub'), 1e-9));
    });
  });

  group('currency', () {
    test('the reporting factor scales every band once, and equally', () {
      final usd = _build();
      final mxn = _build(conversionFactor: 18.0, targetCurrency: 'MXN');
      expect(mxn.income, closeTo(usd.income * 18, 1e-6));
      expect(mxn.spending, closeTo(usd.spending * 18, 1e-6));
      expect(mxn.main.total, closeTo(usd.main.total * 18, 1e-6));
      for (var i = 0; i < usd.main.links.length; i++) {
        expect(
          mxn.main.links[i].value,
          closeTo(usd.main.links[i].value * 18, 1e-6),
        );
      }
    });

    test('income rows are converted per row before they are summed', () {
      // 4,000 USD + 18,000 MXN. At 18 MXN/USD the MXN leg is 1,000 USD, so
      // the attributed total is 5,000 — NOT 22,000.
      final txs = [
        {
          'date': '2026-07-15',
          'amount': 4000.0,
          'currency': 'USD',
          'category': 'INCOME',
          'user_description': 'Payroll',
        },
        {
          'date': '2026-07-20',
          'amount': 18000.0,
          'currency': 'MXN',
          'category': 'INCOME',
          'user_description': 'Consultoria',
        },
        // Predates the window → proves the loaded page covers it.
        {
          'date': '2026-05-02',
          'amount': 10.0,
          'currency': 'USD',
          'category': 'INCOME',
          'user_description': 'Old',
        },
      ];
      final slices = attributeIncomeSources(
        transactions: txs,
        monthKeys: const ['2026-07'],
        incomeTotal: 6000.0,
        targetCurrency: 'USD',
        usdMxnRate: 18.0,
        otherLabel: 'Other income',
      )!;
      expect(slices.map((s) => s.label).toList(), [
        'Payroll',
        'Consultoria',
        'Other income',
      ]);
      expect(slices[0].amount, closeTo(4000.0, 1e-9));
      expect(slices[1].amount, closeTo(1000.0, 1e-9));
      // The residual, not a scaled-up guess.
      expect(slices[2].amount, closeTo(1000.0, 1e-9));
      expect(
        slices.fold<double>(0, (s, e) => s + e.amount),
        closeTo(6000.0, 1e-9),
      );
    });
  });

  group('income attribution fails closed', () {
    List<dynamic> covering(double amount) => [
      {
        'date': '2026-07-15',
        'amount': amount,
        'currency': 'USD',
        'category': 'INCOME',
        'user_description': 'Payroll',
      },
      {
        'date': '2026-05-02',
        'amount': 10.0,
        'currency': 'USD',
        'category': 'INCOME',
        'user_description': 'Old',
      },
    ];

    test('no row predates the window → no attribution', () {
      final slices = attributeIncomeSources(
        transactions: const [
          {
            'date': '2026-07-15',
            'amount': 4000.0,
            'currency': 'USD',
            'category': 'INCOME',
            'user_description': 'Payroll',
          },
        ],
        monthKeys: const ['2026-07'],
        incomeTotal: 6000.0,
        targetCurrency: 'USD',
        usdMxnRate: 18.0,
        otherLabel: 'Other income',
      );
      expect(slices, isNull);
    });

    test('overshooting the authoritative total → no attribution', () {
      // The client can't replicate every server-side anti-join; when the
      // rows we can see already exceed the endpoint's income, guessing which
      // to drop would be fabrication.
      expect(
        attributeIncomeSources(
          transactions: covering(9000.0),
          monthKeys: const ['2026-07'],
          incomeTotal: 6000.0,
          targetCurrency: 'USD',
          usdMxnRate: 18.0,
          otherLabel: 'Other income',
        ),
        isNull,
      );
    });

    test('transfers and card payments are not income', () {
      expect(
        isIncomeRow({'amount': 100.0, 'category': 'TRANSFER_IN'}),
        isFalse,
      );
      expect(isIncomeRow({'amount': 100.0, 'category': 'INVESTMENT'}), isFalse);
      expect(
        isIncomeRow({
          'amount': 100.0,
          'category': 'LOAN_PAYMENTS',
          'category_detailed': 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT',
        }),
        isFalse,
      );
      expect(
        isIncomeRow({
          'amount': 100.0,
          'category': 'INCOME',
          'category_detailed': 'INCOME_TAX_REFUND',
        }),
        isFalse,
      );
      expect(isIncomeRow({'amount': -100.0, 'category': 'INCOME'}), isFalse);
      expect(isIncomeRow({'amount': 100.0, 'category': 'INCOME'}), isTrue);
      // A user re-tag wins, exactly like the backend's effective category.
      expect(
        isIncomeRow({
          'amount': 100.0,
          'category': 'INCOME',
          'user_category': 'Transfer',
        }),
        isFalse,
      );
    });

    test('a failed attribution renders one honest unattributed node', () {
      final d = _build(transactions: const <dynamic>[]);
      expect(d.incomeAttributed, isFalse);
      final sources = d.main.nodes.where((n) => n.depth == 0).toList();
      expect(sources.length, 1);
      expect(sources.single.label, 'Income');
      expect(sources.single.value, closeTo(6000.0, 1e-9));
    });

    test('a successful attribution flags itself and still conserves', () {
      final d = _build(
        transactions: [
          {
            'date': '2026-07-15',
            'amount': 4000.0,
            'currency': 'USD',
            'category': 'INCOME',
            'user_description': 'Payroll',
          },
          {
            'date': '2026-05-02',
            'amount': 10.0,
            'currency': 'USD',
            'category': 'INCOME',
            'user_description': 'Old',
          },
        ],
      );
      expect(d.incomeAttributed, isTrue);
      expect(
        d.main.nodes.where((n) => n.depth == 0).map((n) => n.label).toList(),
        ['Payroll', 'Other income'],
      );
      expect(_sumIn(d.main, 'hub'), closeTo(6000.0, 1e-9));
    });
  });

  group('the FX conversion node', () {
    List<dynamic> transfers() => [
      {
        'source_date': '2026-07-10',
        'source_amount': 1000.0,
        'source_currency': 'USD',
        'dest_amount': 18000.0,
        'dest_currency': 'MXN',
      },
      {
        'source_date': '2026-07-18',
        'source_amount': 500.0,
        'source_currency': 'USD',
        'dest_amount': 8900.0,
        'dest_currency': 'MXN',
      },
      // Outside the selected month.
      {
        'source_date': '2026-06-10',
        'source_amount': 700.0,
        'source_currency': 'USD',
        'dest_amount': 12000.0,
        'dest_currency': 'MXN',
      },
      // Same currency on both legs — not a conversion.
      {
        'source_date': '2026-07-12',
        'source_amount': 300.0,
        'source_currency': 'USD',
        'dest_amount': 300.0,
        'dest_currency': 'USD',
      },
    ];

    test('builds currency → conversion → currency from linked pairs', () {
      final d = _build(fxTransfers: transfers());
      expect(d.fxTransferCount, 2);
      expect(d.fx.nodeById('fxout:USD')!.value, closeTo(1500.0, 1e-9));
      expect(d.fx.nodeById('fx')!.label, 'FX conversion');
      expect(d.fx.nodeById('fx')!.value, closeTo(1500.0, 1e-9));
      expect(d.fx.nodeById('fxin:MXN')!.value, closeTo(1500.0, 1e-9));
      expect(d.fx.links.length, 2);
      // Native legs are quoted separately, never added together.
      expect(d.fxSent, {'USD': 1500.0});
      expect(d.fxReceived, {'MXN': 26900.0});
    });

    test('an MXN→USD leg is converted before it joins a USD-side total', () {
      final d = _build(
        fxTransfers: [
          {
            'source_date': '2026-07-10',
            'source_amount': 36000.0,
            'source_currency': 'MXN',
            'dest_amount': 1990.0,
            'dest_currency': 'USD',
          },
        ],
      );
      // 36,000 MXN at 18 = 2,000 USD — not 36,000 dropped into a USD sum.
      expect(d.fx.nodeById('fxout:MXN')!.value, closeTo(2000.0, 1e-9));
      expect(d.fxSent, {'MXN': 36000.0});
      expect(d.fxReceived, {'USD': 1990.0});
    });

    test('both sides are sized by the source leg, not by rate drift', () {
      // Destination leg deliberately generous (19.5 implied vs an 18.0 spot):
      // sizing the outgoing side by the dest leg would draw a phantom gain.
      final d = _build(
        fxTransfers: [
          {
            'source_date': '2026-07-10',
            'source_amount': 1000.0,
            'source_currency': 'USD',
            'dest_amount': 19500.0,
            'dest_currency': 'MXN',
          },
        ],
      );
      expect(d.fx.nodeById('fxout:USD')!.value, closeTo(1000.0, 1e-9));
      expect(d.fx.nodeById('fxin:MXN')!.value, closeTo(1000.0, 1e-9));
    });

    test('no links in the window → no band, and nothing invented', () {
      final d = _build(
        fxTransfers: const [
          {
            'source_date': '2020-01-10',
            'source_amount': 1000.0,
            'source_currency': 'USD',
            'dest_amount': 18000.0,
            'dest_currency': 'MXN',
          },
        ],
      );
      expect(d.fx.isEmpty, isTrue);
      expect(d.fxTransferCount, 0);
      expect(d.fxSent, isEmpty);
    });
  });

  group('degenerate periods', () {
    test('no trends at all → an empty card, not a zero-width river', () {
      final d = _build(trends: const <Map<String, dynamic>>[]);
      expect(d.isEmpty, isTrue);
      expect(d.monthKeys, isEmpty);
      expect(d.income, 0);
    });

    test('a month with no money movement is empty', () {
      final d = _build(
        trends: [
          {
            'month': '2026-07',
            'income': 0.0,
            'spending': 0.0,
            'invested': 0.0,
            'transferred': 0.0,
          },
        ],
        categories: {'months': <String>[], 'categories': <dynamic>[]},
      );
      expect(d.main.isEmpty, isTrue);
    });

    test(
      'income with no spending at all still draws: it all went to savings',
      () {
        final d = _build(
          trends: [
            {
              'month': '2026-07',
              'income': 2500.0,
              'spending': 0.0,
              'invested': 0.0,
              'transferred': 0.0,
            },
          ],
          categories: {'months': <String>[], 'categories': <dynamic>[]},
        );
        expect(d.main.links.length, 2);
        expect(
          d.main.links.firstWhere((l) => l.target == 'out:saved').value,
          closeTo(2500.0, 1e-9),
        );
      },
    );

    test('a single category is a valid, conserved diagram', () {
      final d = _build(
        trends: [
          {
            'month': '2026-07',
            'income': 1000.0,
            'spending': 1000.0,
            'invested': 0.0,
            'transferred': 0.0,
          },
        ],
        categories: {
          'months': ['2026-07'],
          'categories': [
            {
              'category': 'RENT_AND_UTILITIES',
              'total': 1000.0,
              'monthly': [
                {'month': '2026-07', 'amount': 1000.0},
              ],
            },
          ],
        },
      );
      expect(d.main.links.length, 2);
      expect(d.net, closeTo(0.0, 1e-9));
      expect(d.main.nodeById('out:saved'), isNull);
      expect(_sumOut(d.main, 'hub'), closeTo(1000.0, 1e-9));
    });
  });

  group('layout', () {
    const diagram = SankeyDiagram(
      nodes: [
        SankeyNode(
          id: 'a',
          label: 'A',
          depth: 0,
          value: 75,
          kind: SankeyNodeKind.incomeSource,
        ),
        SankeyNode(
          id: 'b',
          label: 'B',
          depth: 0,
          value: 25,
          kind: SankeyNodeKind.incomeSource,
        ),
        SankeyNode(
          id: 'hub',
          label: 'Hub',
          depth: 1,
          value: 100,
          kind: SankeyNodeKind.hub,
        ),
        SankeyNode(
          id: 'x',
          label: 'X',
          depth: 2,
          value: 100,
          kind: SankeyNodeKind.category,
        ),
      ],
      links: [
        SankeyLink(source: 'a', target: 'hub', value: 75),
        SankeyLink(source: 'b', target: 'hub', value: 25),
        SankeyLink(source: 'hub', target: 'x', value: 100),
      ],
      total: 100,
    );

    test('one scale for the whole diagram: equal widths mean equal money', () {
      final layout = layoutSankey(
        diagram,
        width: 500,
        height: 200,
        leftGutter: 100,
        rightGutter: 100,
        nodeWidth: 10,
        nodeGap: 10,
      );
      final a = layout.bands[0];
      final b = layout.bands[1];
      // 75 vs 25 under one scale.
      expect(a.thickness / b.thickness, closeTo(3.0, 1e-6));
      expect(a.thickness, closeTo(75 * layout.scale, 1e-6));
      // The hub's incoming bands exactly fill its bar.
      final hub = layout.nodeRects['hub']!;
      expect(a.thickness + b.thickness, closeTo(hub.height, 1e-6));
      expect(layout.bands[2].thickness, closeTo(hub.height, 1e-6));
    });

    test('columns stay inside the gutters', () {
      final layout = layoutSankey(
        diagram,
        width: 500,
        height: 200,
        leftGutter: 100,
        rightGutter: 100,
        nodeWidth: 10,
        nodeGap: 10,
      );
      expect(layout.nodeRects['a']!.left, 100);
      expect(layout.nodeRects['x']!.right, 400);
      for (final rect in layout.nodeRects.values) {
        expect(rect.left, greaterThanOrEqualTo(100));
        expect(rect.right, lessThanOrEqualTo(400));
      }
    });

    test('the top inset shifts every column down', () {
      final layout = layoutSankey(
        diagram,
        width: 500,
        height: 200,
        leftGutter: 100,
        rightGutter: 100,
        top: 14,
        nodeWidth: 10,
        nodeGap: 10,
      );
      for (final rect in layout.nodeRects.values) {
        expect(rect.top, greaterThanOrEqualTo(14));
        expect(rect.bottom, lessThanOrEqualTo(14 + 200 + 1e-6));
      }
    });

    test('hit-testing finds the band the pointer is actually over', () {
      final layout = layoutSankey(
        diagram,
        width: 500,
        height: 200,
        leftGutter: 100,
        rightGutter: 100,
        nodeWidth: 10,
        nodeGap: 10,
      );
      final a = layout.bands[0];
      final mid = Offset(
        (a.sourceRect.right + a.targetRect.left) / 2,
        a.sourceTop + a.thickness / 2,
      );
      expect(sankeyBandAt(layout, mid)?.link.source, 'a');
      // Far outside every ribbon.
      expect(sankeyBandAt(layout, const Offset(2, 2)), isNull);
    });

    test('a degenerate box lays out nothing rather than NaN geometry', () {
      expect(
        layoutSankey(
          diagram,
          width: 60,
          height: 200,
          leftGutter: 100,
          rightGutter: 100,
        ).isEmpty,
        isTrue,
      );
      expect(
        layoutSankey(
          SankeyDiagram.empty,
          width: 500,
          height: 200,
          leftGutter: 100,
          rightGutter: 100,
        ).isEmpty,
        isTrue,
      );
    });
  });
}
