import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/responsive.dart';
import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../models/enums.dart';
import '../../models/prefs.dart';
import '../../models/shop.dart';
import '../../services/backend.dart';
import '../../services/cart_service.dart';
import '../../services/coupon_loyalty_service.dart';
import '../../services/payment/payment_gateway.dart';
import '../../services/pickup_qr_service.dart';
import '../../services/shop_recommendation_service.dart';
import '../../widgets/animations.dart';
import '../../widgets/bits.dart';
import '../../widgets/cards.dart';
import '../../widgets/common.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/nutrition_card.dart';
import '../../widgets/search_tracker.dart';
import '../shell/main_shell.dart';

/// Achat direct depuis la fiche produit (sans passer par le panier).
class DirectPurchase {
  const DirectPurchase(this.productId, this.quantity);
  final String productId;
  final int quantity;
}

/// Catalogue de la boutique en grille (GridView.builder).
class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key});

  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> {
  static const _listKey = 'shop';
  final _query = TextEditingController();
  late FilterValues _filters = Backend.I.library.savedFilters(_listKey);
  late final SearchTracker _tracker;

  @override
  void initState() {
    super.initState();
    _tracker = SearchTracker(_query, () => _results(_filters).length);
  }

  @override
  void dispose() {
    _tracker.dispose();
    _query.dispose();
    super.dispose();
  }

  void _setFilters(FilterValues f) {
    setState(() => _filters = f);
    Backend.I.library.saveFilters(_listKey, f);
  }

  List<Product> _results(FilterValues f) =>
      Backend.I.productService.search(query: _query.text, filters: f);

  static final _groups = [
    FilterGroup(
      id: 'category',
      title: 'Catégorie',
      icon: Icons.category_outlined,
      options: [
        for (final c in ProductCategory.values)
          FilterOption(c.name, c.label, icon: c.icon),
      ],
    ),
    const FilterGroup(
      id: 'price',
      title: 'Prix',
      icon: Icons.payments_outlined,
      options: [
        FilterOption('lt20', 'Moins de 20 DT'),
        FilterOption('20_50', '20 à 50 DT'),
        FilterOption('50_100', '50 à 100 DT'),
        FilterOption('gt100', 'Plus de 100 DT'),
      ],
    ),
    const FilterGroup(
      id: 'promo',
      title: 'Bons plans',
      icon: Icons.local_offer_outlined,
      options: [FilterOption('only', 'En promotion', icon: Icons.sell)],
    ),
    const FilterGroup(
      id: 'stock',
      title: 'Disponibilité',
      icon: Icons.inventory_2_outlined,
      options: [FilterOption('in', 'En stock', icon: Icons.check)],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return Scaffold(
      appBar: AppBar(
        leading: const ShellMenuButton(),
        title: const Text('Boutique'),
        actions: [
          IconButton(
            tooltip: 'Mes commandes',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => Navigator.pushNamed(context, Routes.orders),
          ),
          const CartButton(),
        ],
      ),
      body: ListenableBuilder(
        listenable: b.bus,
        builder: (context, _) {
          final products = _results(_filters);
          final me = b.auth.currentUser!;
          // Sélection affichée sur l'accueil de la boutique uniquement
          // (sans recherche ni filtre).
          final picks =
              me.isMember &&
                  _query.text.trim().isEmpty &&
                  _filters.activeCount == 0
              ? b.recommendations.forGoal()
              : const <ShopRecommendation>[];
          final padding = pagePadding(context, maxWidth: 1200, top: Gap.s);
          return Column(
            children: [
              FilterSearchBar(
                groups: _groups,
                values: _filters,
                onChanged: _setFilters,
                resultCount: (f) => _results(f).length,
                hint: 'Rechercher un produit',
                query: _query,
                onQuery: (_) => setState(() {}),
              ),
              Expanded(
                child: products.isEmpty
                    ? EmptyState(
                        icon: Icons.search_off,
                        title: 'Aucun produit',
                        message:
                            'Essayez une autre recherche ou d\'autres filtres.',
                        action: _filters.activeCount > 0
                            ? 'Tout effacer'
                            : null,
                        onAction: () => _setFilters({}),
                      )
                    : CustomScrollView(
                        slivers: [
                          if (picks.isNotEmpty)
                            SliverPadding(
                              padding: padding.copyWith(top: 0, bottom: 0),
                              sliver: SliverToBoxAdapter(
                                child: RecommendationStrip(
                                  key: const Key('goal_picks'),
                                  title:
                                      'Pour votre objectif : '
                                      '${me.goal.label.toLowerCase()}',
                                  items: picks,
                                  goal: me.goal,
                                ),
                              ),
                            ),
                          SliverPadding(
                            padding: padding,
                            sliver: SliverGrid.builder(
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 220,
                                    mainAxisSpacing: Gap.m,
                                    crossAxisSpacing: Gap.m,
                                    childAspectRatio: 0.68,
                                  ),
                              itemCount: products.length,
                              itemBuilder: (_, i) => FadeSlideIn(
                                index: i,
                                child: ProductCard(product: products[i]),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Fiche produit : photos, description, stock, ajout panier / achat direct.
class ProductDetailScreen extends StatefulWidget {
  const ProductDetailScreen({super.key, required this.productId});
  final String productId;

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  int _qty = 1;
  int _photo = 0;

  @override
  void initState() {
    super.initState();
    final p = Backend.I.productService.byId(widget.productId);
    if (p != null) Backend.I.analytics.viewItem(p);
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return ListenableBuilder(
      listenable: b.bus,
      builder: (context, _) {
        final p = b.productService.byId(widget.productId);
        if (p == null || (!p.active && !b.auth.currentUser!.isAdmin)) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.search_off,
              title: 'Produit indisponible',
              message: 'Ce produit n\'est plus en vente.',
            ),
          );
        }
        final images = p.images.isEmpty ? <String?>[null] : p.images;
        final together = b.recommendations.boughtTogether(p.id);
        final maxQty = p.stock.clamp(1, 10);
        if (_qty > maxQty) _qty = maxQty;
        return Scaffold(
          appBar: AppBar(
            title: Text(p.category.label),
            actions: const [CartButton()],
          ),
          body: ListView(
            children: [
              SizedBox(
                height: 300,
                child: Stack(
                  children: [
                    PageView.builder(
                      itemCount: images.length,
                      onPageChanged: (i) => setState(() => _photo = i),
                      itemBuilder: (_, i) => i == 0
                          ? Hero(
                              tag: 'pr_${p.id}',
                              child: NetImage(
                                images[i],
                                width: double.infinity,
                                fallbackIcon: p.category.icon,
                              ),
                            )
                          : NetImage(images[i], width: double.infinity),
                    ),
                    if (images.length > 1)
                      Positioned(
                        bottom: Gap.s,
                        left: 0,
                        right: 0,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (var i = 0; i < images.length; i++)
                              AnimatedContainer(
                                duration: kAnim,
                                margin: const EdgeInsets.all(3),
                                width: i == _photo ? 18 : 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: i == _photo
                                      ? AppColors.gold
                                      : AppColors.surface,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: AppColors.heading),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(Gap.m),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name, style: AppText.title(size: 22)),
                    const SizedBox(height: Gap.s),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          Fmt.money(p.effectivePrice),
                          style: AppText.display(
                            color: AppColors.redText,
                            size: 26,
                          ),
                        ),
                        if (p.onPromo) ...[
                          const SizedBox(width: Gap.s),
                          Text(
                            Fmt.money(p.price),
                            style: AppText.label().copyWith(
                              decoration: TextDecoration.lineThrough,
                            ),
                          ),
                          const SizedBox(width: Gap.s),
                          Pill(
                            '-${p.discountPercent} %',
                            color: AppColors.gold,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: Gap.s),
                    p.inStock
                        ? Pill(
                            p.stock <= 5
                                ? 'Plus que ${p.stock} en stock'
                                : 'En stock',
                            color: p.stock <= 5
                                ? AppColors.gold
                                : AppColors.success,
                            icon: Icons.inventory_2_outlined,
                          )
                        : const Pill(
                            'Rupture de stock',
                            color: AppColors.red,
                            icon: Icons.block,
                          ),
                    const SizedBox(height: Gap.m),
                    Text(p.description, style: AppText.body()),
                    if (showNutritionCard(p)) ...[
                      const SizedBox(height: Gap.m),
                      NutritionCard(product: p),
                    ],
                    const SizedBox(height: Gap.l),
                    if (p.inStock) ...[
                      Row(
                        children: [
                          Text('Quantité', style: AppText.subtitle(size: 15)),
                          const Spacer(),
                          _QtyStepper(
                            value: _qty,
                            max: maxQty,
                            onChanged: (v) => setState(() => _qty = v),
                          ),
                        ],
                      ),
                      const SizedBox(height: Gap.m),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              key: const Key('add_to_cart'),
                              onPressed: () async {
                                final ok = await runAction(
                                  context,
                                  () async => b.cart.add(p, _qty),
                                );
                                if (ok && context.mounted) {
                                  ScaffoldMessenger.of(context)
                                    ..hideCurrentSnackBar()
                                    ..showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'Ajouté au panier ($_qty)',
                                        ),
                                        action: SnackBarAction(
                                          label: 'Voir',
                                          onPressed: () => Navigator.pushNamed(
                                            context,
                                            Routes.cart,
                                          ),
                                        ),
                                      ),
                                    );
                                }
                              },
                              icon: const Icon(Icons.add_shopping_cart),
                              label: const Text('Au panier'),
                            ),
                          ),
                          const SizedBox(width: Gap.s),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () => Navigator.pushNamed(
                                context,
                                Routes.checkout,
                                arguments: DirectPurchase(p.id, _qty),
                              ),
                              child: const Text('Acheter'),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (together.isNotEmpty)
                      RecommendationStrip(
                        key: const Key('bought_together'),
                        title: 'Souvent achetés ensemble',
                        items: together,
                      ),
                    const SizedBox(height: Gap.xl),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Bandeau horizontal de produits recommandés, chacun avec sa raison.
class RecommendationStrip extends StatelessWidget {
  const RecommendationStrip({
    super.key,
    required this.title,
    required this.items,
    this.goal,
  });

  final String title;
  final List<ShopRecommendation> items;
  final Goal? goal;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title, padded: false),
        SizedBox(
          height: 262,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: Gap.s),
            itemBuilder: (_, i) => _RecommendationCard(
              key: ValueKey(items[i].product.id),
              item: items[i],
              goal: goal,
            ),
          ),
        ),
      ],
    );
  }
}

class _RecommendationCard extends StatefulWidget {
  const _RecommendationCard({super.key, required this.item, this.goal});
  final ShopRecommendation item;
  final Goal? goal;

  @override
  State<_RecommendationCard> createState() => _RecommendationCardState();
}

class _RecommendationCardState extends State<_RecommendationCard> {
  // Raison calculée affichée tout de suite, remplacée par la phrase de
  // l'IA si elle arrive (sinon elle reste).
  late final Future<String> _reason = Backend.I.recommendations.explain(
    widget.item,
    goal: widget.goal,
  );

  @override
  Widget build(BuildContext context) {
    final p = widget.item.product;
    return SizedBox(
      width: 200,
      child: GfCard(
        padding: EdgeInsets.zero,
        margin: const EdgeInsets.only(bottom: 4),
        onTap: () =>
            Navigator.pushNamed(context, Routes.product, arguments: p.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 96,
              width: double.infinity,
              child: NetImage(
                p.images.isEmpty ? null : p.images.first,
                fallbackIcon: p.category.icon,
                cacheWidth: 400,
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(Gap.s),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.subtitle(size: 14),
                    ),
                    Text(
                      Fmt.money(p.effectivePrice),
                      style: AppText.stat(color: AppColors.redText, size: 14),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: FutureBuilder<String>(
                        future: _reason,
                        initialData: widget.item.reason,
                        builder: (_, snap) => Text(
                          snap.data ?? widget.item.reason,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.label(size: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QtyStepper extends StatelessWidget {
  const _QtyStepper({
    required this.value,
    required this.max,
    required this.onChanged,
  });
  final int value;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.outline),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Diminuer',
            onPressed: value > 1 ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              '$value',
              key: ValueKey(value),
              style: AppText.stat(size: 16),
            ),
          ),
          IconButton(
            tooltip: 'Augmenter',
            onPressed: value < max ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

/// Panier : quantités, total, passage au paiement.
class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = Backend.I.cart;
    return ListenableBuilder(
      listenable: Listenable.merge([cart, cart.discount, Backend.I.bus]),
      builder: (context, _) {
        final lines = cart.lines;
        final quote = lines.isEmpty ? null : quoteFor(lines, cart.discount).$1;
        return Scaffold(
          appBar: AppBar(title: const Text('Mon panier')),
          body: lines.isEmpty
              ? EmptyState(
                  icon: Icons.shopping_bag_outlined,
                  title: 'Panier vide',
                  message:
                      'Compléments, accessoires, vêtements… faites-vous plaisir !',
                  action: 'Voir la boutique',
                  onAction: () => Navigator.pop(context),
                )
              : ListView.separated(
                  padding: pagePadding(context, maxWidth: 900, bottom: Gap.m),
                  itemCount: lines.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: Gap.s),
                  itemBuilder: (_, i) {
                    if (i == lines.length) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DiscountPanel(lines: lines, choice: cart.discount),
                          const SizedBox(height: Gap.s),
                          GfCard(child: QuoteSummary(quote: quote!)),
                        ],
                      );
                    }
                    final l = lines[i];
                    return Dismissible(
                      key: ValueKey(l.product.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: Gap.l),
                        decoration: BoxDecoration(
                          color: AppColors.red,
                          borderRadius: BorderRadius.circular(Gap.radius),
                        ),
                        child: const Icon(Icons.delete, color: AppColors.white),
                      ),
                      onDismissed: (_) => cart.remove(l.product.id),
                      child: GfCard(
                        padding: const EdgeInsets.all(Gap.s),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: NetImage(
                                l.product.images.isEmpty
                                    ? null
                                    : l.product.images.first,
                                width: 72,
                                height: 72,
                                cacheWidth: 220,
                              ),
                            ),
                            const SizedBox(width: Gap.s),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l.product.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.subtitle(size: 14),
                                  ),
                                  Text(
                                    Fmt.money(l.product.effectivePrice),
                                    style: AppText.label(),
                                  ),
                                  Text(
                                    Fmt.money(l.total),
                                    style: AppText.stat(
                                      color: AppColors.redText,
                                      size: 15,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            _QtyStepper(
                              value: l.quantity,
                              max: l.product.stock.clamp(1, 10),
                              onChanged: (v) => runAction(
                                context,
                                () async => cart.setQuantity(l.product.id, v),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
          bottomNavigationBar: lines.isEmpty
              ? null
              : _TotalBar(
                  total: quote!.total,
                  label: 'Passer au paiement',
                  onPressed: () =>
                      Navigator.pushNamed(context, Routes.checkout),
                ),
        );
      },
    );
  }
}

class _TotalBar extends StatelessWidget {
  const _TotalBar({
    required this.total,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });
  final double total;
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.all(Gap.m),
        decoration: BoxDecoration(
          color: AppColors.surface,
          boxShadow: [
            BoxShadow(
              color: Color(0x14002855),
              blurRadius: 12,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text('Total', style: AppText.subtitle()),
                const Spacer(),
                Text(
                  Fmt.money(total),
                  key: const Key('cart_total'),
                  style: AppText.display(color: AppColors.redText, size: 24),
                ),
              ],
            ),
            const SizedBox(height: Gap.s),
            LoadingButton(
              key: const Key('checkout_button'),
              label: label,
              icon: Icons.lock_outline,
              loading: loading,
              onPressed: onPressed,
            ),
          ],
        ),
      ),
    );
  }
}

/// Paiement : Stripe Checkout (mode test) si une clé est fournie,
/// sinon passerelle simulée avec formulaire carte.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key, this.direct});
  final DirectPurchase? direct;

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final _formKey = GlobalKey<FormState>();
  final _number = TextEditingController(text: '4242 4242 4242 4242');
  final _expiry = TextEditingController(text: '12/30');
  final _cvc = TextEditingController(text: '123');
  final _holder = TextEditingController();
  bool _paying = false;

  /// Achat direct : choix propre ; sinon celui du panier.
  late final DiscountChoice _choice = widget.direct == null
      ? Backend.I.cart.discount
      : DiscountChoice();

  @override
  void initState() {
    super.initState();
    _holder.text = Backend.I.auth.currentUser?.fullName ?? '';
  }

  @override
  void dispose() {
    for (final c in [_number, _expiry, _cvc, _holder]) {
      c.dispose();
    }
    if (widget.direct != null) _choice.dispose();
    super.dispose();
  }

  List<CartLine> get _lines {
    final b = Backend.I;
    final d = widget.direct;
    if (d != null) {
      final p = b.products.byId(d.productId);
      return p == null ? [] : [CartLine(product: p, quantity: d.quantity)];
    }
    return b.cart.lines;
  }

  Future<void> _pay() async {
    final b = Backend.I;
    final lines = _lines;
    final gateway = b.payment;
    if (gateway is SimulatedPaymentGateway &&
        !_formKey.currentState!.validate()) {
      return;
    }
    setState(() => _paying = true);
    try {
      b.orderService.checkStock(lines); // 1re vérification du stock
      // Règles du code promo et des points vérifiées avant le paiement.
      final quote = b.couponLoyalty.quote(
        lines,
        code: _choice.code,
        points: _choice.points,
      );
      final total = quote.total;
      PaymentResult? result;
      if (gateway is HostedPaymentGateway) {
        final me = b.auth.currentUser!;
        final session = await gateway.createSession(
          lines: lines,
          customerEmail: me.email,
          customerName: me.fullName,
          total: total,
          discount: quote.discount,
          stamp: quote.stamp,
        );
        if (!mounted) return;
        final finished = await Navigator.push<bool?>(
          context,
          gfRoute(HostedCheckoutPage(session: session, gateway: gateway)),
        );
        if (finished == false) {
          throw const BusinessRuleException('Paiement annulé.');
        }
        // Page fermée (fin du paiement ou retour) : le statut fait foi.
        result = await gateway.verify(session.id);
      } else if (gateway is SimulatedPaymentGateway) {
        result = await gateway.charge(
          cardNumber: _number.text,
          expiry: _expiry.text,
          cvc: _cvc.text,
          amount: total,
          now: b.now(),
        );
      }
      if (result == null || !result.success) {
        throw const BusinessRuleException('Paiement non finalisé.');
      }
      // Le stock est revérifié au moment d'enregistrer la commande.
      final order = await b.orderService.placeOrder(
        lines,
        result,
        couponCode: _choice.code,
        points: _choice.points,
      );
      // Facture par e-mail si EmailJS est configuré (sans bloquer l'écran).
      unawaited(b.invoices.email(order.id));
      if (widget.direct == null) b.cart.clear();
      if (mounted) {
        Navigator.pushReplacementNamed(
          context,
          Routes.orderConfirmation,
          arguments: order.id,
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    final lines = _lines;
    final simulated = b.payment is SimulatedPaymentGateway;
    return ListenableBuilder(
      listenable: _choice,
      builder: (context, _) => _build(context, lines, simulated),
    );
  }

  Widget _build(BuildContext context, List<CartLine> lines, bool simulated) {
    final b = Backend.I;
    final quote = lines.isEmpty ? null : quoteFor(lines, _choice).$1;
    final total = quote?.total ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Paiement')),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: pagePadding(context, maxWidth: 760, bottom: Gap.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Récapitulatif', style: AppText.title(size: 18)),
              const SizedBox(height: Gap.s),
              GfCard(
                child: Column(
                  children: [
                    for (final l in lines)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${l.quantity} × ${l.product.name}',
                                style: AppText.body(size: 14),
                              ),
                            ),
                            Text(
                              Fmt.money(l.total),
                              style: AppText.subtitle(size: 14),
                            ),
                          ],
                        ),
                      ),
                    const Divider(),
                    if (quote != null) QuoteSummary(quote: quote),
                    Row(
                      children: [
                        Text('Total à payer', style: AppText.subtitle()),
                        const Spacer(),
                        Text(
                          Fmt.money(total),
                          style: AppText.stat(color: AppColors.redText),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (lines.isNotEmpty) ...[
                const SizedBox(height: Gap.s),
                DiscountPanel(lines: lines, choice: _choice),
              ],
              const SizedBox(height: Gap.l),
              Row(
                children: [
                  Icon(Icons.lock, color: AppColors.successText, size: 18),
                  const SizedBox(width: Gap.xs),
                  Expanded(
                    child: Text(
                      b.payment.label,
                      style: AppText.subtitle(size: 14),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.s),
              if (simulated) ...[
                GfCard(
                  color: AppColors.cream,
                  child: InfoRow(
                    Icons.science_outlined,
                    'Mode test : carte 4242 4242 4242 4242 acceptée ; 4000 0000 0000 0002 refusée. Aucune donnée de carte n\'est enregistrée.',
                  ),
                ),
                const SizedBox(height: Gap.m),
                TextFormField(
                  controller: _holder,
                  decoration: const InputDecoration(
                    labelText: 'Titulaire de la carte',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) => (v ?? '').trim().length < 3
                      ? 'Nom du titulaire requis.'
                      : null,
                ),
                const SizedBox(height: Gap.m),
                TextFormField(
                  key: const Key('card_number'),
                  controller: _number,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[\d ]')),
                    LengthLimitingTextInputFormatter(23),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Numéro de carte',
                    prefixIcon: Icon(Icons.credit_card),
                  ),
                  validator: (v) => SimulatedPaymentGateway.luhnValid(v ?? '')
                      ? null
                      : 'Numéro de carte invalide.',
                ),
                const SizedBox(height: Gap.m),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _expiry,
                        keyboardType: TextInputType.datetime,
                        decoration: const InputDecoration(
                          labelText: 'Expiration (MM/AA)',
                        ),
                        validator: (v) =>
                            SimulatedPaymentGateway.validateExpiry(
                              v ?? '',
                              b.now(),
                            ),
                      ),
                    ),
                    const SizedBox(width: Gap.s),
                    Expanded(
                      child: TextFormField(
                        controller: _cvc,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: 'CVC'),
                        validator: (v) =>
                            RegExp(r'^\d{3,4}$').hasMatch(v?.trim() ?? '')
                            ? null
                            : 'CVC invalide.',
                      ),
                    ),
                  ],
                ),
              ] else
                GfCard(
                  color: AppColors.cream,
                  child: InfoRow(
                    Icons.open_in_browser,
                    'Vous allez être redirigé vers la page sécurisée Stripe '
                    '(mode test) : carte de test 4242 4242 4242 4242, date '
                    'future, CVC au choix. Montant converti en euros. '
                    "Aucune donnée de carte n'est enregistrée par GymFlow.",
                  ),
                ),
              const SizedBox(height: 120),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _TotalBar(
        total: total,
        label: 'Payer ${Fmt.money(total)}',
        loading: _paying,
        onPressed: lines.isEmpty ? null : _pay,
      ),
    );
  }
}

/// Page de paiement hébergée par Stripe, ouverte dans un WebView.
/// Renvoie `true` à la fin du paiement, `false` en cas d'abandon explicite ;
/// le statut est ensuite toujours revérifié auprès de l'API.
class HostedCheckoutPage extends StatefulWidget {
  const HostedCheckoutPage({
    super.key,
    required this.session,
    required this.gateway,
  });
  final HostedSession session;
  final HostedPaymentGateway gateway;

  @override
  State<HostedCheckoutPage> createState() => _HostedCheckoutPageState();
}

class _HostedCheckoutPageState extends State<HostedCheckoutPage> {
  // Dans un navigateur, le WebView n'existe pas : la page Stripe s'ouvre
  // dans un nouvel onglet (voir _webBody).
  WebViewController? _controller;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) return;
    final g = widget.gateway;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => setState(() => _progress = p),
          onNavigationRequest: (req) {
            if (g.isFinished(req.url)) {
              Navigator.pop(context, true);
              return NavigationDecision.prevent;
            }
            if (g.isCancelled(req.url)) {
              Navigator.pop(context, false);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.session.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.gateway.pageTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Terminé'),
          ),
        ],
        bottom: _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(
                  value: _progress / 100,
                  color: AppColors.gold,
                ),
              )
            : null,
      ),
      body: kIsWeb
          ? _webBody()
          : Column(
              children: [
                const _TestCardBanner(),
                Expanded(child: WebViewWidget(controller: _controller!)),
              ],
            ),
    );
  }

  /// Version navigateur : la page de paiement Stripe s'ouvre dans un nouvel
  /// onglet ; on revient ici pour confirmer, puis le statut est revérifié
  /// auprès de Stripe (rien n'est accepté sur la seule parole de l'écran).
  Widget _webBody() {
    return ListView(
      padding: pagePadding(context, maxWidth: 600),
      children: [
        const _TestCardBanner(),
        const SizedBox(height: Gap.s),
        GfCard(
          color: AppColors.cream,
          child: InfoRow(
            Icons.open_in_new,
            "La page de paiement Stripe (mode test) s'ouvre dans un nouvel "
            'onglet. Payez avec la carte de test 4242 4242 4242 4242, une date '
            'future et un CVC au choix, puis revenez ici.',
          ),
        ),
        const SizedBox(height: Gap.m),
        FilledButton.icon(
          key: const Key('stripe_open'),
          onPressed: () => launchUrl(
            Uri.parse(widget.session.url),
            webOnlyWindowName: '_blank',
          ),
          icon: const Icon(Icons.lock_outline),
          label: const Text('Ouvrir la page Stripe'),
        ),
        const SizedBox(height: Gap.s),
        OutlinedButton.icon(
          key: const Key('stripe_done'),
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.check),
          label: const Text("J'ai payé : vérifier"),
        ),
        const SizedBox(height: Gap.s),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
      ],
    );
  }
}

/// Rappel de la carte de test Stripe, au-dessus de la page de paiement.
/// Les champs de la page Stripe sont dans un cadre sécurisé que
/// l'application ne peut pas remplir : le numéro se copie en un geste.
class _TestCardBanner extends StatelessWidget {
  const _TestCardBanner();

  static const number = '4242424242424242';

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.cream,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
        child: Row(
          children: [
            const Icon(Icons.credit_card, size: 20),
            const SizedBox(width: Gap.s),
            Expanded(
              child: Text(
                'Carte de test : 4242 4242 4242 4242 · date 12/34 · CVC 123 · '
                'nom au choix',
                key: const Key('test_card_hint'),
                style: AppText.label(),
              ),
            ),
            TextButton(
              key: const Key('test_card_copy'),
              onPressed: () async {
                await Clipboard.setData(const ClipboardData(text: number));
                if (context.mounted) {
                  showSnack(context, 'Numéro de carte de test copié.');
                }
              },
              child: const Text('Copier'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Confirmation animée de commande.
class OrderConfirmationScreen extends StatelessWidget {
  const OrderConfirmationScreen({super.key, required this.orderId});
  final String orderId;

  @override
  Widget build(BuildContext context) {
    final o = Backend.I.orderService.byId(orderId)!;
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(Gap.l),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 700),
                    curve: Curves.elasticOut,
                    builder: (_, v, child) =>
                        Transform.scale(scale: v, child: child),
                    child: const CircleAvatar(
                      radius: 48,
                      backgroundColor: AppColors.success,
                      child: Icon(
                        Icons.check,
                        color: AppColors.white,
                        size: 56,
                      ),
                    ),
                  ),
                  const SizedBox(height: Gap.l),
                  Text(
                    'Merci pour votre achat !',
                    key: const Key('order_confirmed'),
                    textAlign: TextAlign.center,
                    style: AppText.title(size: 24),
                  ),
                  const SizedBox(height: Gap.s),
                  Text(
                    'Commande ${o.number} · ${Fmt.money(o.total)}\nÀ retirer à l\'accueil dès qu\'elle est préparée.',
                    textAlign: TextAlign.center,
                    style: AppText.body(color: AppColors.inkSoft),
                  ),
                  const SizedBox(height: Gap.xl),
                  ElevatedButton(
                    onPressed: () => Navigator.pushReplacementNamed(
                      context,
                      Routes.order,
                      arguments: o.id,
                    ),
                    child: const Text('Voir le reçu'),
                  ),
                  const SizedBox(height: Gap.s),
                  OutlinedButton(
                    onPressed: () => Navigator.popUntil(
                      context,
                      (r) => r.settings.name == Routes.home || r.isFirst,
                    ),
                    child: const Text('Continuer mes achats'),
                  ),
                ],
              ),
            ),
          ),
          const Positioned.fill(child: Confetti(pieces: 60)),
        ],
      ),
    );
  }
}

Color orderStatusColor(OrderStatus s) => switch (s) {
  OrderStatus.paid => AppColors.navy,
  OrderStatus.prepared => AppColors.gold,
  OrderStatus.delivered => AppColors.success,
};

/// Historique des commandes de l'utilisateur.
class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return ListenableBuilder(
      listenable: b.bus,
      builder: (context, _) {
        final orders = b.orderService.mine();
        return Scaffold(
          appBar: AppBar(title: const Text('Mes commandes')),
          body: orders.isEmpty
              ? const EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'Aucune commande',
                  message: 'Vos achats en boutique apparaîtront ici.',
                )
              : ListView.separated(
                  padding: pagePadding(context, maxWidth: 900, bottom: Gap.m),
                  itemCount: orders.length,
                  separatorBuilder: (_, _) => const SizedBox(height: Gap.s),
                  itemBuilder: (_, i) => FadeSlideIn(
                    index: i,
                    child: OrderTile(order: orders[i]),
                  ),
                ),
        );
      },
    );
  }
}

class OrderTile extends StatelessWidget {
  const OrderTile({
    super.key,
    required this.order,
    this.showClient = false,
    this.trailing,
  });
  final ShopOrder order;
  final bool showClient;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final o = order;
    final client = showClient ? Backend.I.users.byId(o.userId)?.fullName : null;
    return GfCard(
      onTap: () => Navigator.pushNamed(context, Routes.order, arguments: o.id),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: AppColors.cream,
            child: Text('${o.itemCount}', style: AppText.subtitle(size: 14)),
          ),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(o.number, style: AppText.subtitle(size: 15)),
                Text(
                  [?client, Fmt.dateTime(o.createdAt)].join(' · '),
                  style: AppText.label(size: 12),
                ),
                const SizedBox(height: 4),
                Pill(o.status.label, color: orderStatusColor(o.status)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                Fmt.money(o.total),
                style: AppText.stat(color: AppColors.redText, size: 16),
              ),
              ?trailing,
            ],
          ),
        ],
      ),
    );
  }
}

/// Reçu détaillé d'une commande.
class OrderDetailScreen extends StatelessWidget {
  const OrderDetailScreen({super.key, required this.orderId});
  final String orderId;

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return ListenableBuilder(
      listenable: b.bus,
      builder: (context, _) {
        final o = b.orderService.byId(orderId);
        if (o == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.search_off,
              title: 'Commande introuvable',
              message: '',
            ),
          );
        }
        final client = b.users.byId(o.userId);
        return Scaffold(
          appBar: AppBar(title: Text('Reçu ${o.number}')),
          body: ListView(
            padding: pagePadding(context, maxWidth: 900, bottom: Gap.m),
            children: [
              GfCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Image.asset('assets/images/logo.png', width: 44),
                        const SizedBox(width: Gap.s),
                        Expanded(
                          child: Text(
                            'GymFlow Club',
                            style: AppText.title(size: 18),
                          ),
                        ),
                        Pill(o.status.label, color: orderStatusColor(o.status)),
                      ],
                    ),
                    const Divider(height: Gap.l),
                    InfoRow(Icons.tag, 'Commande ${o.number}'),
                    InfoRow(Icons.event, Fmt.dateTime(o.createdAt)),
                    InfoRow(Icons.person_outline, client?.fullName ?? ''),
                    InfoRow(
                      Icons.credit_card,
                      '${paymentMethodLabel(o.paymentMethod)} · réf. ${o.paymentRef}',
                    ),
                    const Divider(height: Gap.l),
                    for (final l in o.lines)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${l.quantity} × ${l.name}',
                                style: AppText.body(size: 14),
                              ),
                            ),
                            Text(
                              Fmt.money(l.total),
                              style: AppText.subtitle(size: 14),
                            ),
                          ],
                        ),
                      ),
                    const Divider(height: Gap.l),
                    if (o.discount > 0 || o.stamp > 0) ...[
                      _AmountRow('Sous-total', o.subtotal),
                      if (o.discount > 0)
                        _AmountRow(
                          'Réduction${o.discountLabel == null ? '' : ' · ${o.discountLabel}'}',
                          -o.discount,
                        ),
                      if (o.stamp > 0) _AmountRow('Timbre fiscal', o.stamp),
                      const SizedBox(height: Gap.xs),
                    ],
                    Row(
                      children: [
                        Text('Total payé TTC', style: AppText.subtitle()),
                        const Spacer(),
                        Text(
                          Fmt.money(o.total),
                          key: const Key('order_total'),
                          style: AppText.stat(color: AppColors.redText),
                        ),
                      ],
                    ),
                    if (o.pointsEarned > 0)
                      InfoRow(
                        Icons.stars,
                        '+${o.pointsEarned} points de fidélité',
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Gap.m),
              _OrderTimeline(status: o.status),
              if (o.status != OrderStatus.delivered &&
                  o.userId == b.auth.currentUser!.id) ...[
                const SizedBox(height: Gap.m),
                PickupQrCard(key: ValueKey(o.status), orderId: o.id),
              ],
              const SizedBox(height: Gap.m),
              _InvoiceActions(orderId: o.id),
              if (b.auth.currentUser!.isAdmin &&
                  o.status != OrderStatus.delivered) ...[
                const SizedBox(height: Gap.l),
                ElevatedButton.icon(
                  onPressed: () => runAction(
                    context,
                    () => b.orderService.advance(o.id),
                    success: 'Statut mis à jour, client prévenu.',
                  ),
                  icon: const Icon(Icons.arrow_forward),
                  label: Text(
                    o.status == OrderStatus.paid
                        ? 'Marquer « préparée »'
                        : 'Marquer « remise »',
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

String paymentMethodLabel(String method) => switch (method) {
  'stripe_test' => 'Stripe (test)',
  _ => 'Paiement test simulé',
};

class _AmountRow extends StatelessWidget {
  const _AmountRow(this.label, this.amount);
  final String label;
  final double amount;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(label, style: AppText.body(size: 14))),
        Text(
          amount < 0 ? '-${Fmt.money(-amount)}' : Fmt.money(amount),
          style: AppText.subtitle(
            size: 14,
            color: amount < 0 ? AppColors.successText : AppColors.heading,
          ),
        ),
      ],
    ),
  );
}

class _OrderTimeline extends StatelessWidget {
  const _OrderTimeline({required this.status});
  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    return GfCard(
      child: Row(
        children: [
          for (final s in OrderStatus.values) ...[
            Expanded(
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: kAnim,
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: s.index <= status.index
                          ? AppColors.success
                          : AppColors.divider,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.check,
                      size: 18,
                      color: s.index <= status.index
                          ? AppColors.white
                          : AppColors.inkSoft,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(s.label, style: AppText.label(size: 12)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Devis du panier avec le code et les points choisis ; si une règle n'est
/// plus respectée (panier modifié, code expiré…), devis sans réduction et
/// message d'erreur à afficher.
(CheckoutQuote, String?) quoteFor(List<CartLine> lines, DiscountChoice c) {
  final s = Backend.I.couponLoyalty;
  try {
    return (s.quote(lines, code: c.code, points: c.points), null);
  } catch (e) {
    return (s.quote(lines), friendlyError(e));
  }
}

/// Code promo et points de fidélité (panier et paiement).
class DiscountPanel extends StatefulWidget {
  const DiscountPanel({super.key, required this.lines, required this.choice});
  final List<CartLine> lines;
  final DiscountChoice choice;

  @override
  State<DiscountPanel> createState() => _DiscountPanelState();
}

class _DiscountPanelState extends State<DiscountPanel> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final b = Backend.I;
    final c = widget.choice;
    final ok = await runAction(context, () async {
      // Les règles du code sont vérifiées par le service.
      b.couponLoyalty.quote(widget.lines, code: _code.text, points: c.points);
      c.set(code: _code.text);
    }, success: 'Code promo appliqué.');
    if (ok) _code.clear();
  }

  void _setPoints(int points) {
    final c = widget.choice;
    runAction(context, () async {
      Backend.I.couponLoyalty.quote(widget.lines, code: c.code, points: points);
      c.set(points: points);
    });
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    final c = widget.choice;
    final me = b.auth.currentUser!;
    final (quote, error) = quoteFor(widget.lines, c);
    final balance = b.couponLoyalty.balanceOf(me.id);
    final max = b.couponLoyalty.maxRedeemable(
      me.id,
      quote.subtotal - quote.couponDiscount,
    );
    const block = CouponLoyaltyService.pointsBlock;
    return GfCard(
      key: const Key('discount_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Code promo', style: AppText.subtitle(size: 15)),
          const SizedBox(height: Gap.s),
          if (quote.coupon != null)
            Row(
              children: [
                Flexible(
                  child: Pill(
                    '${quote.coupon!.code} · ${quote.coupon!.shortValue}',
                    color: AppColors.success,
                    icon: Icons.local_offer,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => c.set(clearCode: true),
                  child: const Text('Retirer'),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('coupon_field'),
                    controller: _code,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      hintText: 'Ex. BIENVENUE10',
                      prefixIcon: Icon(Icons.local_offer_outlined),
                    ),
                    onSubmitted: (_) => _apply(),
                  ),
                ),
                const SizedBox(width: Gap.s),
                OutlinedButton(
                  key: const Key('coupon_apply'),
                  onPressed: _apply,
                  child: const Text('Appliquer'),
                ),
              ],
            ),
          if (error != null) ...[
            const SizedBox(height: Gap.xs),
            Text(
              error,
              style: AppText.label(color: AppColors.redText, size: 12),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: c.reset,
                child: const Text('Retirer la réduction'),
              ),
            ),
          ],
          const Divider(height: Gap.l),
          Row(
            children: [
              Icon(Icons.stars, color: AppColors.heading),
              const SizedBox(width: Gap.s),
              Expanded(
                child: Text(
                  'Points de fidélité : $balance '
                  '($block points = '
                  '${Fmt.money(CouponLoyaltyService.blockValue)})',
                  key: const Key('loyalty_balance'),
                  style: AppText.body(size: 14),
                ),
              ),
            ],
          ),
          if (max > 0 || c.points > 0)
            Row(
              children: [
                Expanded(
                  child: Text(
                    c.points == 0
                        ? 'Utiliser des points'
                        : '${c.points} points = -'
                              '${Fmt.money(CouponLoyaltyService.pointsValue(c.points))}',
                    style: AppText.subtitle(size: 14),
                  ),
                ),
                IconButton(
                  tooltip: '$block points de moins',
                  onPressed: c.points > 0
                      ? () => _setPoints(c.points - block)
                      : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                IconButton(
                  key: const Key('points_more'),
                  tooltip: '$block points de plus',
                  onPressed: c.points < max
                      ? () => _setPoints(c.points + block)
                      : null,
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(
                '1 point par dinar dépensé et 10 points par séance terminée.',
                style: AppText.label(size: 12),
              ),
            ),
        ],
      ),
    );
  }
}

/// Sous-total, réductions et timbre fiscal (le total est affiché à part).
class QuoteSummary extends StatelessWidget {
  const QuoteSummary({super.key, required this.quote});
  final CheckoutQuote quote;

  @override
  Widget build(BuildContext context) {
    final q = quote;
    Widget row(String label, double amount, {bool minus = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AppText.body(size: 14))),
          Text(
            '${minus ? '-' : ''}${Fmt.money(amount)}',
            style: AppText.subtitle(
              size: 14,
              color: minus ? AppColors.successText : AppColors.heading,
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row('Sous-total', q.subtotal),
        if (q.couponDiscount > 0)
          row('Code ${q.coupon!.code}', q.couponDiscount, minus: true),
        if (q.pointsDiscount > 0)
          row('${q.pointsUsed} points', q.pointsDiscount, minus: true),
        if (q.stamp > 0) row('Timbre fiscal', q.stamp),
      ],
    );
  }
}

/// QR code de retrait signé (régénéré à chaque ouverture du reçu).
class PickupQrCard extends StatefulWidget {
  const PickupQrCard({super.key, required this.orderId});
  final String orderId;

  @override
  State<PickupQrCard> createState() => _PickupQrCardState();
}

class _PickupQrCardState extends State<PickupQrCard> {
  late final String _data = Backend.I.pickup.generate(widget.orderId);

  @override
  Widget build(BuildContext context) {
    final exp = PickupQrService.expiryOf(_data);
    return GfCard(
      key: const Key('pickup_qr'),
      child: Column(
        children: [
          Text('QR code de retrait', style: AppText.title(size: 17)),
          const SizedBox(height: Gap.s),
          Container(
            color: AppColors.white,
            padding: const EdgeInsets.all(Gap.s),
            child: QrImageView(
              data: _data,
              size: 200,
              semanticsLabel: 'QR code de retrait de la commande',
            ),
          ),
          const SizedBox(height: Gap.s),
          Text(
            'Présentez ce code à l\'accueil pour retirer votre commande'
            '${exp == null ? '' : ' (valable jusqu\'au ${Fmt.dateTime(exp)})'}.',
            textAlign: TextAlign.center,
            style: AppText.label(),
          ),
        ],
      ),
    );
  }
}

/// Téléchargement de la facture PDF et envoi par e-mail.
class _InvoiceActions extends StatefulWidget {
  const _InvoiceActions({required this.orderId});
  final String orderId;

  @override
  State<_InvoiceActions> createState() => _InvoiceActionsState();
}

class _InvoiceActionsState extends State<_InvoiceActions> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    setState(() => _busy = true);
    await runAction(context, action, success: success);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return Wrap(
      spacing: Gap.s,
      runSpacing: Gap.s,
      children: [
        OutlinedButton.icon(
          key: const Key('invoice_pdf'),
          onPressed: _busy
              ? null
              : () => _run(() async {
                  final bytes = await b.invoices.pdf(widget.orderId);
                  await Printing.sharePdf(
                    bytes: bytes,
                    filename: b.invoices.fileName(widget.orderId),
                  );
                }),
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: const Text('Facture PDF'),
        ),
        if (b.email.invoiceEnabled)
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final ok = await b.invoices.email(widget.orderId);
                    if (!ok) {
                      throw const BusinessRuleException(
                        'Envoi impossible pour le moment. La facture reste '
                        'téléchargeable.',
                      );
                    }
                  }, success: 'Facture envoyée par e-mail.'),
            icon: const Icon(Icons.mail_outline),
            label: const Text('Recevoir par e-mail'),
          ),
      ],
    );
  }
}
