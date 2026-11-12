import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../models/shop.dart';
import 'backend.dart';
import 'coupon_loyalty_service.dart';

/// Code promo et points choisis pour un achat (panier ou achat direct).
/// Les règles sont vérifiées par [CouponLoyaltyService.quote].
class DiscountChoice extends ChangeNotifier {
  String? code;
  int points = 0;

  void set({String? code, int? points, bool clearCode = false}) {
    if (clearCode) this.code = null;
    if (code != null) this.code = code.trim().toUpperCase();
    if (points != null) this.points = points;
    notifyListeners();
  }

  void reset() {
    if (code == null && points == 0) return;
    code = null;
    points = 0;
    notifyListeners();
  }
}

/// Panier partagé (singleton `ChangeNotifier` écouté par la pastille du
/// panier et l'écran Panier).
class CartService extends ChangeNotifier {
  CartService(this._b);
  final Backend _b;

  final List<CartLine> _lines = [];

  /// Code promo et points du panier (remis à zéro avec le panier).
  final DiscountChoice discount = DiscountChoice();

  List<CartLine> get lines => List.unmodifiable(_lines);
  bool get isEmpty => _lines.isEmpty;
  int get count => _lines.fold(0, (s, l) => s + l.quantity);
  double get total => _lines.fold(0, (s, l) => s + l.total);

  int quantityOf(String productId) {
    for (final l in _lines) {
      if (l.product.id == productId) return l.quantity;
    }
    return 0;
  }

  void add(Product product, [int quantity = 1]) {
    _b.requireUser();
    final fresh = _b.products.byId(product.id) ?? product;
    if (!fresh.active) {
      throw const BusinessRuleException('Ce produit n\'est plus disponible.');
    }
    if (!fresh.inStock) {
      throw const BusinessRuleException('Produit en rupture de stock.');
    }
    final i = _lines.indexWhere((l) => l.product.id == product.id);
    final next = (i >= 0 ? _lines[i].quantity : 0) + quantity;
    if (next > fresh.stock) {
      throw BusinessRuleException('Stock disponible : ${fresh.stock}.');
    }
    if (i >= 0) {
      _lines[i] = _lines[i].copyWith(product: fresh, quantity: next);
    } else {
      _lines.add(CartLine(product: fresh, quantity: next));
    }
    notifyListeners();
  }

  void setQuantity(String productId, int quantity) {
    final i = _lines.indexWhere((l) => l.product.id == productId);
    if (i < 0) return;
    if (quantity <= 0) {
      _lines.removeAt(i);
    } else {
      final stock = _b.products.byId(productId)?.stock ?? 0;
      if (quantity > stock) {
        throw BusinessRuleException('Stock disponible : $stock.');
      }
      _lines[i] = _lines[i].copyWith(quantity: quantity);
    }
    notifyListeners();
  }

  void remove(String productId) {
    _lines.removeWhere((l) => l.product.id == productId);
    notifyListeners();
  }

  void clear() {
    discount.reset();
    if (_lines.isEmpty) return;
    _lines.clear();
    notifyListeners();
  }

  /// Met à jour prix/stock après une modification du catalogue.
  void refreshProducts() {
    for (var i = _lines.length - 1; i >= 0; i--) {
      final p = _b.products.byId(_lines[i].product.id);
      if (p == null || !p.active) {
        _lines.removeAt(i);
      } else {
        _lines[i] = _lines[i].copyWith(product: p);
      }
    }
    notifyListeners();
  }
}
