import 'dart:math';

import '../../core/legal.dart';

import '../../models/checkin.dart';
import '../../models/content.dart';
import '../../models/course.dart';
import '../../models/enums.dart';
import '../../models/exercise.dart';
import '../../models/loyalty.dart';
import '../../models/misc.dart';
import '../../models/nutrition.dart';
import '../../models/privacy.dart';
import '../../models/ramadan.dart';
import '../../models/risk.dart';
import '../../models/session_log.dart';
import '../../models/session_pack.dart';
import '../../models/shop.dart';
import '../../models/user.dart';
import '../../models/workout.dart';
import '../backend.dart';
import '../aladhan_api.dart';
import '../churn_risk_service.dart';
import 'seed_exercises.dart';
import 'seed_translations.dart';
import 'seed_workouts.dart';

/// Compte de démonstration affiché sur l'écran de connexion.
class DemoAccount {
  const DemoAccount(this.label, this.email, this.password, this.role);
  final String label;
  final String email;
  final String password;
  final UserRole role;
}

/// Comptes de démo (panneau retirable sur l'écran de connexion).
const demoAccounts = <DemoAccount>[
  DemoAccount(
    'Karim — Super Admin',
    'admin@gymflow.tn',
    'Admin2026!',
    UserRole.superAdmin,
  ),
  DemoAccount(
    'Amira — Coach yoga',
    'amira@gymflow.tn',
    'Coach2026!',
    UserRole.coach,
  ),
  DemoAccount(
    'Mehdi — Coach force',
    'mehdi@gymflow.tn',
    'Coach2026!',
    UserRole.coach,
  ),
  DemoAccount(
    'Sarra — Coach cardio',
    'sarra@gymflow.tn',
    'Coach2026!',
    UserRole.coach,
  ),
  DemoAccount(
    'Nour — Abonnée (nouvelle)',
    'nour@gymflow.tn',
    'Membre2026!',
    UserRole.member,
  ),
  DemoAccount(
    'Ahmed — Abonné confirmé',
    'ahmed@gymflow.tn',
    'Membre2026!',
    UserRole.member,
  ),
  DemoAccount(
    'Hedi — Abonnement expiré',
    'hedi@gymflow.tn',
    'Membre2026!',
    UserRole.member,
  ),
  DemoAccount(
    'Walid — Compte désactivé',
    'walid@gymflow.tn',
    'Membre2026!',
    UserRole.member,
  ),
];

/// Charge le jeu de données de démonstration au premier lancement.
class SeedService {
  SeedService(this._b);
  final Backend _b;
  final Random _rnd = Random(2026);

  static const _seedKey = 'seed_version';
  static const _seedVersion = '1';

  late DateTime _now;
  late DateTime _today;
  final Map<String, String> _ids = {};

  Future<void> seedIfEmpty() async {
    if (await _b.store.getMeta(_seedKey) == _seedVersion) return;
    if (_b.users.count > 0) return;
    await seed();
    await _b.store.setMeta(_seedKey, _seedVersion);
    await _b.store.setMeta(_i18nKey, _i18nVersion);
  }

  static const _i18nKey = 'content_i18n';
  static const _i18nVersion = '1';

  /// Mise à niveau d'une base déjà remplie (application déjà installée) :
  /// noms anglais des contenus de démonstration et exemples de créations
  /// des membres.
  Future<void> upgrade() async {
    await _upgradeNutrition();
    await _upgradeOrderHistory();
    await _upgradeCoupons();
    await _upgradeCoursePacks();
    await _upgradePremiumCourse();
    await _upgradeCourseHistory();
    await _upgradeCheckIns();
    await _upgradeRamadan();
    if (await _b.store.getMeta(_i18nKey) == _i18nVersion) return;
    if (_b.users.count > 0) {
      _now = _b.now();
      _today = DateTime(_now.year, _now.month, _now.day);
      await _translateContent();
      if (_b.users.byId('u_ines') != null &&
          _b.workouts.byId('w_ines_core') == null) {
        await _seedMemberCreations();
      }
    }
    await _b.store.setMeta(_i18nKey, _i18nVersion);
  }

  static const _nutritionKey = 'shop_nutrition';
  static const _nutritionVersion = '2';

  /// Valeurs nutritionnelles des produits de démonstration (saisies par la
  /// salle, cohérentes avec leurs descriptions), pour la carte Nutrition.
  static const demoNutrition = {
    'pr_whey': Nutrition(
      proteins: 80,
      carbs: 6,
      sugars: 4,
      fat: 6,
      kcal: 390,
      servingG: 30,
      netWeightG: 2000,
      nutriScore: 'not-applicable',
      allergens: ['Lait'],
    ),
    'pr_isolate': Nutrition(
      proteins: 90,
      carbs: 2,
      sugars: 1.5,
      fat: 1,
      kcal: 370,
      servingG: 30,
      netWeightG: 900,
      nutriScore: 'not-applicable',
      allergens: ['Lait'],
    ),
    'pr_bar': Nutrition(
      proteins: 33,
      carbs: 30,
      sugars: 5,
      fat: 15,
      kcal: 380,
      servingG: 60,
      netWeightG: 720,
      allergens: ['Lait', 'Arachides', 'Soja'],
    ),
    // Pour 100 ml ; pack de 6 bouteilles de 500 ml.
    'pr_iso': Nutrition(
      proteins: 0,
      carbs: 6.4,
      sugars: 6,
      fat: 0,
      kcal: 26,
      servingG: 500,
      netWeightG: 3000,
    ),
  };

  /// Ajoute la nutrition de démonstration aux produits qui n'en ont pas
  /// (base neuve ou application déjà installée).
  Future<void> _upgradeNutrition() async {
    if (await _b.store.getMeta(_nutritionKey) == _nutritionVersion) return;
    for (final e in demoNutrition.entries) {
      final p = _b.products.byId(e.key);
      if (p != null && p.nutrition == null) {
        await _b.products.save(
          Product.fromJson({...p.toJson(), 'nutrition': e.value.toJson()}),
        );
      }
    }
    await _b.store.setMeta(_nutritionKey, _nutritionVersion);
  }

  DateTime _day(int offset, [int hour = 0, int minute = 0]) =>
      DateTime(_today.year, _today.month, _today.day + offset, hour, minute);

  Future<void> seed() async {
    _now = _b.now();
    _today = DateTime(_now.year, _now.month, _now.day);
    await _seedUsers();
    await _seedContent();
    await _translateContent();
    await _seedCourses();
    await _seedHistory();
    await _seedMemberCreations();
    await _seedShop();
    await _seedAnnouncements();
  }

  // ------------------------------------------------------------------ Comptes

  Future<void> _seedUsers() async {
    Subscription sub(SubscriptionType t, int startOffset) {
      final start = _day(startOffset);
      final end = DateTime(start.year, start.month + t.months, start.day);
      return Subscription(type: t, start: start, end: end);
    }

    final users = <String, (AppUser, String)>{
      'admin': (
        AppUser(
          id: 'u_admin',
          email: 'admin@gymflow.tn',
          fullName: 'Karim Belhadj',
          role: UserRole.superAdmin,
          gender: Gender.male,
          age: 44,
          phone: '+216 71 000 100',
          createdAt: _day(-400),
        ),
        'Admin2026!',
      ),
      'amira': (
        AppUser(
          id: 'u_amira',
          email: 'amira@gymflow.tn',
          fullName: 'Amira Trabelsi',
          role: UserRole.coach,
          gender: Gender.female,
          age: 33,
          specialty: 'Yoga, Pilates & mobilité',
          bio: 'Professeure de yoga certifiée RYT-500, 10 ans d\'expérience.',
          createdAt: _day(-380),
        ),
        'Coach2026!',
      ),
      'mehdi': (
        AppUser(
          id: 'u_mehdi',
          email: 'mehdi@gymflow.tn',
          fullName: 'Mehdi Jaziri',
          role: UserRole.coach,
          gender: Gender.male,
          age: 36,
          specialty: 'Musculation & force',
          bio:
              'Préparateur physique, ancien haltérophile de l\'équipe nationale.',
          createdAt: _day(-370),
        ),
        'Coach2026!',
      ),
      'sarra': (
        AppUser(
          id: 'u_sarra',
          email: 'sarra@gymflow.tn',
          fullName: 'Sarra Haddad',
          role: UserRole.coach,
          gender: Gender.female,
          age: 29,
          specialty: 'HIIT, cardio, boxe & danse',
          bio: 'Coach cardio et boxe, énergie garantie à chaque cours !',
          createdAt: _day(-300),
        ),
        'Coach2026!',
      ),
      'nour': (
        AppUser(
          id: 'u_nour',
          email: 'nour@gymflow.tn',
          fullName: 'Nour Ben Ammar',
          role: UserRole.member,
          gender: Gender.female,
          age: 24,
          heightCm: 165,
          weightKg: 61,
          goal: Goal.fitness,
          weeklyGoal: 3,
          subscription: sub(SubscriptionType.monthly, -3),
          createdAt: _day(-3),
        ),
        'Membre2026!',
      ),
      'ahmed': (
        AppUser(
          id: 'u_ahmed',
          email: 'ahmed@gymflow.tn',
          fullName: 'Ahmed Gharbi',
          role: UserRole.member,
          gender: Gender.male,
          age: 31,
          heightCm: 180,
          weightKg: 82,
          goal: Goal.muscleGain,
          weeklyGoal: 4,
          activeProgramId: 'p_ppl',
          subscription: sub(SubscriptionType.yearly, -120),
          createdAt: _day(-240),
        ),
        'Membre2026!',
      ),
      'leila': (
        AppUser(
          id: 'u_leila',
          email: 'leila@gymflow.tn',
          fullName: 'Leila Mansour',
          role: UserRole.member,
          gender: Gender.female,
          age: 45,
          heightCm: 162,
          weightKg: 64,
          goal: Goal.fitness,
          weeklyGoal: 3,
          activeProgramId: 'p_fullbody',
          subscription: sub(SubscriptionType.quarterly, -40),
          createdAt: _day(-200),
        ),
        'Membre2026!',
      ),
      'omar': (
        AppUser(
          id: 'u_omar',
          email: 'omar@gymflow.tn',
          fullName: 'Omar Chaabane',
          role: UserRole.member,
          gender: Gender.male,
          age: 58,
          heightCm: 174,
          weightKg: 88,
          goal: Goal.fitness,
          weeklyGoal: 2,
          activeProgramId: 'p_fullbody',
          subscription: sub(SubscriptionType.quarterly, -30),
          createdAt: _day(-35),
        ),
        'Membre2026!',
      ),
      'ines': (
        AppUser(
          id: 'u_ines',
          email: 'ines@gymflow.tn',
          fullName: 'Ines Kammoun',
          role: UserRole.member,
          gender: Gender.female,
          age: 29,
          heightCm: 168,
          weightKg: 57,
          goal: Goal.endurance,
          weeklyGoal: 4,
          activeProgramId: 'p_endurance',
          subscription: sub(SubscriptionType.yearly, -200),
          createdAt: _day(-210),
        ),
        'Membre2026!',
      ),
      'rami': (
        AppUser(
          id: 'u_rami',
          email: 'rami@gymflow.tn',
          fullName: 'Rami Bouzid',
          role: UserRole.member,
          gender: Gender.male,
          age: 22,
          heightCm: 183,
          weightKg: 78,
          goal: Goal.muscleGain,
          weeklyGoal: 5,
          activeProgramId: 'p_ppl',
          subscription: sub(SubscriptionType.monthly, -12),
          createdAt: _day(-150),
        ),
        'Membre2026!',
      ),
      'salma': (
        AppUser(
          id: 'u_salma',
          email: 'salma@gymflow.tn',
          fullName: 'Salma Jebali',
          role: UserRole.member,
          gender: Gender.female,
          age: 36,
          heightCm: 160,
          weightKg: 76,
          goal: Goal.weightLoss,
          weeklyGoal: 3,
          activeProgramId: 'p_weightloss_home',
          subscription: sub(SubscriptionType.quarterly, -60),
          createdAt: _day(-70),
        ),
        'Membre2026!',
      ),
      'hedi': (
        AppUser(
          id: 'u_hedi',
          email: 'hedi@gymflow.tn',
          fullName: 'Hedi Ferchichi',
          role: UserRole.member,
          gender: Gender.male,
          age: 40,
          heightCm: 177,
          weightKg: 90,
          goal: Goal.weightLoss,
          weeklyGoal: 3,
          subscription: sub(SubscriptionType.monthly, -40),
          createdAt: _day(-90),
        ),
        'Membre2026!',
      ),
      'walid': (
        AppUser(
          id: 'u_walid',
          email: 'walid@gymflow.tn',
          fullName: 'Walid Sassi',
          role: UserRole.member,
          active: false,
          gender: Gender.male,
          age: 27,
          goal: Goal.muscleGain,
          subscription: sub(SubscriptionType.monthly, -50),
          createdAt: _day(-26),
        ),
        'Membre2026!',
      ),
    };

    await _b.users.saveAll(
      users.entries.map((e) => _withPrivacy(e.key, e.value.$1)),
    );
    for (final e in users.entries) {
      _ids[e.key] = e.value.$1.id;
      await _b.auth.setPassword(e.value.$1.id, e.value.$2);
    }
    await _b.auditRepo.save(
      AuditEntry(
        id: 'a_seed_walid',
        actorId: 'u_admin',
        actorName: 'Karim Belhadj',
        action: 'Désactivation',
        details: 'Walid Sassi (Abonné) — impayés',
        targetId: 'u_walid',
        createdAt: _day(-6, 10, 12),
      ),
    );
    for (final key in [
      'nour',
      'ahmed',
      'leila',
      'omar',
      'ines',
      'rami',
      'salma',
      'hedi',
    ]) {
      await _note(
        key,
        NotificationType.system,
        'Bienvenue chez GymFlow !',
        'Réservez vos cours, lancez vos séances et suivez votre progression.',
        users[key]!.$1.createdAt,
        read: key != 'nour',
      );
    }
    await _note(
      'hedi',
      NotificationType.system,
      'Votre abonnement a expiré',
      'Passez à l\'accueil pour le renouveler et continuer à réserver vos cours.',
      _day(-10, 9),
    );
  }

  /// Choix de confidentialité des comptes de démo. Les liens sociaux sont
  /// fictifs (domaine example.com et identifiants « gymflow.demo… »).
  AppUser _withPrivacy(String key, AppUser u) {
    final consents = [
      if (u.isMember)
        ConsentRecord(
          type: ConsentType.terms,
          granted: true,
          at: u.createdAt,
          version: Legal.version,
        ),
    ];
    ConsentRecord visible(bool social) => ConsentRecord(
      type: social ? ConsentType.socialLinks : ConsentType.profileVisible,
      granted: true,
      at: u.createdAt.add(const Duration(days: 2)),
      version: Legal.version,
    );
    switch (key) {
      case 'ahmed':
        return u.copyWith(
          privacy: const PrivacySettings(
            profileVisible: true,
            showSocialLinks: true,
          ),
          social: const SocialLinks(
            instagram: 'gymflow.demo.ahmed',
            linkedin: 'https://www.linkedin.com/in/gymflow-demo-ahmed',
            publicEmail: 'ahmed.gharbi@example.com',
          ),
          consents: [...consents, visible(false), visible(true)],
        );
      case 'rami':
        return u.copyWith(
          privacy: const PrivacySettings(
            profileVisible: true,
            showSocialLinks: true,
          ),
          social: const SocialLinks(
            instagram: 'gymflow.demo.rami',
            snapchat: 'gymflow.demo.rami',
          ),
          consents: [...consents, visible(false), visible(true)],
        );
      case 'ines':
        return u.copyWith(
          privacy: const PrivacySettings(
            profileVisible: true,
            showSocialLinks: true,
          ),
          social: const SocialLinks(
            instagram: 'gymflow.demo.ines',
            facebook: 'https://www.facebook.com/gymflow.demo.ines',
            publicEmail: 'ines.kammoun@example.com',
          ),
          consents: [...consents, visible(false), visible(true)],
        );
      case 'leila':
        return u.copyWith(
          privacy: const PrivacySettings(profileVisible: true),
          consents: [...consents, visible(false)],
        );
      default:
        return u.copyWith(consents: consents);
    }
  }

  Future<void> _note(
    String userKey,
    NotificationType type,
    String title,
    String body,
    DateTime at, {
    bool read = false,
    String? route,
    String? refId,
  }) async {
    await _b.notificationsRepo.save(
      AppNotification(
        id: 'n_${_b.notificationsRepo.count + 1}_$userKey',
        userId: _ids[userKey]!,
        type: type,
        title: title,
        body: body,
        createdAt: at,
        read: read,
        route: route,
        refId: refId,
      ),
    );
  }

  // --------------------------------------------------------------- Contenu

  Future<void> _seedContent() async {
    final created = _day(-60);
    await _b.exercises.saveAll(
      seedExercises.map((e) => e.build(_ids[e.author]!, created)),
    );
    final workouts = seedWorkouts(created).map(
      (s) =>
          Workout.fromJson({...s.workout.toJson(), 'authorId': _ids[s.author]}),
    );
    await _b.workouts.saveAll(workouts);
    final programs = seedPrograms(created).map(
      (s) =>
          Program.fromJson({...s.program.toJson(), 'authorId': _ids[s.author]}),
    );
    await _b.programs.saveAll(programs);
  }

  /// Noms anglais et autres appellations (recherche bilingue).
  Future<void> _translateContent() async {
    await _b.exercises.saveAll([
      for (final t in exerciseEn.entries)
        if (_b.exercises.byId('ex_${t.key}') case final e?)
          if (e.altName == null)
            e.copyWith(
              altName: t.value.$1,
              aliases: {...e.aliases, ...t.value.$2}.toList(),
            ),
    ]);
    await _b.workouts.saveAll([
      for (final t in workoutEn.entries)
        if (_b.workouts.byId('w_${t.key}') case final w?)
          if (w.altName == null) w.copyWith(altName: t.value),
    ]);
    await _b.programs.saveAll([
      for (final t in programEn.entries)
        if (_b.programs.byId('p_${t.key}') case final p?)
          if (p.altName == null) p.copyWith(altName: t.value),
    ]);
  }

  /// Exemples de créations de membres, dans chaque état de publication :
  /// publiée (Ines), en attente de validation (Rami), privée (Ahmed),
  /// refusée avec un motif (Leila).
  Future<void> _seedMemberCreations() async {
    WorkoutItem item(
      String ex,
      int sets, {
      int? reps,
      int? sec,
      int rest = 45,
    }) => WorkoutItem(
      exerciseId: 'ex_$ex',
      sets: sets,
      reps: reps,
      durationSec: sec,
      restSec: rest,
    );
    final submitted = _day(-6, 18);
    await _b.workouts.saveAll([
      Workout(
        id: 'w_ines_core',
        name: 'Circuit gainage express',
        altName: 'Express core circuit',
        description:
            'Quinze minutes pour renforcer la sangle abdominale sans matériel, '
            'idéal en fin de séance ou à la maison.',
        focus: 'Abdominaux · Gainage',
        level: Level.beginner,
        goal: Goal.fitness,
        coverImage: unsplash('photo-1571019613454-1cb2f99b2d8b'),
        items: [
          item('plank', 3, sec: 40),
          item('mountain', 3, sec: 30),
          item('russian', 3, reps: 20),
          item('birddog', 2, reps: 12),
        ],
        authorId: 'u_ines',
        createdAt: _day(-20),
        publication: Publication(
          status: ContentStatus.published,
          submittedAt: _day(-18),
          reviewedAt: _day(-17),
          reviewerId: 'u_sarra',
        ),
      ),
      Workout(
        id: 'w_rami_arms',
        name: 'Bras d\'acier',
        altName: 'Arm blaster',
        description:
            'Superséries biceps / triceps pour finir une séance du haut du '
            'corps. Charges modérées, contrôle de la descente.',
        focus: 'Biceps · Triceps',
        level: Level.intermediate,
        goal: Goal.muscleGain,
        items: [
          item('bb_curl', 4, reps: 10, rest: 60),
          item('skull', 4, reps: 10, rest: 60),
          item('hammer', 3, reps: 12),
          item('pushdown', 3, reps: 12),
        ],
        authorId: 'u_rami',
        createdAt: _day(-7),
        publication: Publication(
          status: ContentStatus.pending,
          submittedAt: submitted,
        ),
      ),
      Workout(
        id: 'w_leila_cardio',
        name: 'Cardio rapide',
        description: 'Cardio.',
        level: Level.beginner,
        goal: Goal.weightLoss,
        items: [
          item('jacks', 3, sec: 45, rest: 0),
          item('burpee', 3, reps: 10),
        ],
        authorId: 'u_leila',
        createdAt: _day(-9),
        publication: Publication(
          status: ContentStatus.rejected,
          submittedAt: _day(-8),
          reviewedAt: _day(-7),
          reviewerId: 'u_sarra',
          note:
              'Ajoutez une vraie description (échauffement, intensité) et un '
              'temps de repos entre les séries de jumping jacks.',
        ),
      ),
    ]);
    await _b.exercises.save(
      Exercise(
        id: 'ex_ahmed_diamond',
        name: 'Pompes diamant',
        primaryMuscle: Muscle.triceps,
        secondaryMuscles: const [Muscle.chest],
        equipment: Equipment.bodyweight,
        level: Level.intermediate,
        type: ExerciseType.strength,
        description:
            'Pompes mains rapprochées sous la poitrine, pouces et index qui se '
            'touchent en losange.',
        steps: const [
          'Mains en losange sous le sternum.',
          'Descendre en gardant les coudes près du corps.',
          'Pousser jusqu\'à bras tendus.',
        ],
        authorId: 'u_ahmed',
        createdAt: _day(-3),
        publication: Publication.personal,
      ),
    );
    await _b.workouts.save(
      Workout(
        id: 'w_ahmed_home',
        name: 'Mon push maison',
        description: 'Ma séance du dimanche quand la salle est fermée.',
        focus: 'Pectoraux · Triceps',
        level: Level.intermediate,
        goal: Goal.muscleGain,
        items: [
          item('pushup', 4, reps: 15, rest: 60),
          item('ahmed_diamond', 3, reps: 12, rest: 60),
          item('bench_dips', 3, reps: 15, rest: 60),
        ],
        authorId: 'u_ahmed',
        createdAt: _day(-3),
        publication: Publication.personal,
      ),
    );
  }

  // ----------------------------------------------------------------- Cours

  Future<void> _seedCourses() async {
    final img = unsplash;
    Course c(
      String key,
      String title,
      String description,
      CourseCategory cat,
      Level level,
      String coach,
      String room,
      int capacity,
      int duration,
      DateTime? start,
      String image, {
      int createdDaysAgo = 30,
      bool included = true,
      double price = 0,
    }) => Course(
      id: 'c_$key',
      title: title,
      description: description,
      category: cat,
      level: level,
      coachId: _ids[coach]!,
      room: room,
      capacity: capacity,
      durationMin: duration,
      startAt: start,
      createdAt: _now.subtract(Duration(days: createdDaysAgo, hours: 2)),
      imageUrl: img(image),
      priceIncluded: included,
      price: price,
    );

    const yoga = 'photo-1761035005546-62b8018b212a';
    const yoga2 = 'photo-1651077920873-ac1be1b82290';
    const hiit = 'photo-1517130038641-a774d04afb3c';
    const spin = 'photo-1520877880798-5ee004e3f11e';
    const spin2 = 'photo-1709315821780-3c092a9eddda';
    const box = 'photo-1561532325-7d5231a2dede';
    const ring = 'photo-1716307043003-dbe6a5cc496e';
    const pilates = 'photo-1747239069226-55382c570116';
    const zumba = 'photo-1524594152303-9fd13543fe6e';
    const barbell = 'photo-1722925541142-5db2668ca492';
    const deadlift = 'photo-1517836357463-d25dfeac3438';
    const stretch = 'photo-1683056255281-e52a141924f0';
    const stretch2 = 'photo-1593431763017-c689a61b729a';

    final courses = [
      // Terminés (avec présences et notes)
      c(
        'd1',
        'Yoga Vinyasa',
        'Enchaînements fluides synchronisés avec la respiration.',
        CourseCategory.yoga,
        Level.intermediate,
        'amira',
        'Studio Zen',
        15,
        60,
        _day(-2, 18),
        yoga,
      ),
      c(
        'd2',
        'HIIT 45',
        'Intervalles haute intensité : 40 s d\'effort, 20 s de repos.',
        CourseCategory.hiit,
        Level.intermediate,
        'sarra',
        'Salle Énergie',
        20,
        45,
        _day(-3, 19),
        hiit,
      ),
      c(
        'd3',
        'Spinning Endurance',
        'Montées, sprints et récupération en musique.',
        CourseCategory.spinning,
        Level.beginner,
        'sarra',
        'Studio Vélo',
        18,
        45,
        _day(-5, 7, 30),
        spin,
      ),
      c(
        'd4',
        'Force & technique : squat',
        'Atelier technique pour progresser en sécurité sur le squat.',
        CourseCategory.strength,
        Level.intermediate,
        'mehdi',
        'Plateau musculation',
        10,
        75,
        _day(-6, 18, 30),
        barbell,
      ),
      c(
        'd5',
        'Pilates Core',
        'Renforcement profond de la sangle abdominale.',
        CourseCategory.pilates,
        Level.beginner,
        'amira',
        'Studio Zen',
        12,
        50,
        _day(-8, 12, 15),
        pilates,
      ),
      c(
        'd6',
        'Boxe Cardio',
        'Enchaînements au sac, cardio et coordination.',
        CourseCategory.boxing,
        Level.beginner,
        'sarra',
        'Ring',
        16,
        60,
        _day(-10, 19, 30),
        box,
      ),
      // Programmés (semaine en cours et suivante)
      c(
        's1',
        'Yoga Vinyasa',
        'Enchaînements fluides synchronisés avec la respiration.',
        CourseCategory.yoga,
        Level.intermediate,
        'amira',
        'Studio Zen',
        15,
        60,
        _day(1, 18),
        yoga,
      ),
      c(
        's2',
        'HIIT Express',
        '30 minutes chrono pour la pause déjeuner.',
        CourseCategory.hiit,
        Level.intermediate,
        'sarra',
        'Salle Énergie',
        20,
        30,
        _day(1, 12, 30),
        hiit,
      ),
      c(
        's3',
        'Spinning Sunrise',
        'Réveil musculaire sur le vélo avant le travail.',
        CourseCategory.spinning,
        Level.beginner,
        'sarra',
        'Studio Vélo',
        6,
        45,
        _day(2, 7, 30),
        spin2,
      ),
      c(
        's4',
        'Musculation guidée débutants',
        'Découverte des machines et des gestes de base avec un coach.',
        CourseCategory.strength,
        Level.beginner,
        'mehdi',
        'Plateau musculation',
        8,
        60,
        _day(2, 18, 30),
        barbell,
      ),
      c(
        's5',
        'Zumba Party',
        'Danse fitness sur rythmes latinos : on transpire en s\'amusant.',
        CourseCategory.zumba,
        Level.beginner,
        'sarra',
        'Salle Énergie',
        25,
        55,
        _day(3, 19),
        zumba,
      ),
      c(
        's6',
        'Pilates Reformer — Initiation',
        'Nouveau ! Découvrez le Pilates sur machine Reformer.',
        CourseCategory.pilates,
        Level.beginner,
        'amira',
        'Studio Zen',
        8,
        50,
        _day(4, 10),
        pilates,
        createdDaysAgo: 2,
      ),
      c(
        's7',
        'Boxe Technique',
        'Garde, déplacements et combinaisons au sac et aux pattes d\'ours.',
        CourseCategory.boxing,
        Level.intermediate,
        'sarra',
        'Ring',
        14,
        60,
        _day(5, 19, 30),
        ring,
      ),
      c(
        's8',
        'Stretching & mobilité',
        'Nouveau ! Séance douce pour gagner en souplesse.',
        CourseCategory.stretching,
        Level.beginner,
        'amira',
        'Studio Zen',
        15,
        45,
        _day(8, 9),
        stretch,
        createdDaysAgo: 1,
      ),
      c(
        's9',
        'Clinique soulevé de terre',
        'Nouveau ! Atelier de 90 min en petit groupe pour maîtriser le soulevé de terre.',
        CourseCategory.strength,
        Level.intermediate,
        'mehdi',
        'Plateau musculation',
        6,
        90,
        _day(9, 18),
        deadlift,
        createdDaysAgo: 3,
        included: false,
        price: 25,
      ),
      c(
        's10',
        'Yoga doux seniors',
        'Postures accessibles, équilibre et respiration.',
        CourseCategory.yoga,
        Level.beginner,
        'amira',
        'Studio Zen',
        12,
        50,
        _day(10, 10, 30),
        yoga2,
      ),
      c(
        's11',
        'HIIT 45',
        'Intervalles haute intensité : 40 s d\'effort, 20 s de repos.',
        CourseCategory.hiit,
        Level.intermediate,
        'sarra',
        'Salle Énergie',
        20,
        45,
        _day(11, 19),
        hiit,
      ),
      // À planifier (coach affecté, sans date)
      c(
        'p1',
        'Cross Training découverte',
        'Bientôt : circuits fonctionnels variés en petit groupe.',
        CourseCategory.hiit,
        Level.intermediate,
        'sarra',
        'Salle Énergie',
        12,
        60,
        null,
        hiit,
        createdDaysAgo: 4,
      ),
      c(
        'p2',
        'Yin Yoga & respiration',
        'Bientôt : postures longues et relaxation profonde.',
        CourseCategory.yoga,
        Level.beginner,
        'amira',
        'Studio Zen',
        14,
        75,
        null,
        stretch2,
        createdDaysAgo: 5,
      ),
      c(
        'p3',
        'Kettlebell fondamentaux',
        'Bientôt : swing, goblet squat et get-up en toute sécurité.',
        CourseCategory.strength,
        Level.beginner,
        'mehdi',
        'Plateau musculation',
        10,
        60,
        null,
        deadlift,
        createdDaysAgo: 6,
      ),
    ];
    await _b.courses.saveAll(courses);

    var n = 0;
    Future<void> book(
      String courseKey,
      String userKey, {
      bool? attended,
      int? rating,
      String? comment,
      ReservationStatus status = ReservationStatus.confirmed,
      int daysBefore = 4,
    }) async {
      final course = courses.firstWhere((x) => x.id == 'c_$courseKey');
      final ref = course.startAt ?? _now;
      final r = Reservation(
        id: 'r_seed_${n++}',
        courseId: course.id,
        userId: _ids[userKey]!,
        status: status,
        createdAt: ref.subtract(Duration(days: daysBefore, minutes: n * 7)),
        attended: attended,
        rating: rating,
        comment: comment,
      );
      await _b.reservations.save(r);
      if (status == ReservationStatus.confirmed &&
          course.statusAt(_now) == CourseStatus.scheduled) {
        await _b.notifications.scheduleCourseReminders(r, course);
      }
    }

    // Cours terminés : présences + notes.
    await book(
      'd1',
      'leila',
      attended: true,
      rating: 5,
      comment: 'Amira est géniale, cours très fluide.',
    );
    await book('d1', 'ines', attended: true, rating: 4);
    await book('d1', 'salma', attended: false);
    await book(
      'd2',
      'ines',
      attended: true,
      rating: 5,
      comment: 'Intense mais super motivant !',
    );
    await book('d2', 'rami', attended: true, rating: 4);
    await book('d2', 'salma', attended: true, rating: 5);
    await book('d2', 'ahmed', attended: true, rating: 4);
    await book('d3', 'ines', attended: true, rating: 5);
    await book(
      'd3',
      'omar',
      attended: true,
      rating: 4,
      comment: 'Parfait pour reprendre en douceur.',
    );
    await book('d3', 'leila', attended: true, rating: 4);
    await book(
      'd4',
      'ahmed',
      attended: true,
      rating: 5,
      comment: 'J\'ai enfin compris le placement du dos.',
    );
    await book('d4', 'rami', attended: true, rating: 5);
    await book('d5', 'leila', attended: true, rating: 5);
    await book('d5', 'salma', attended: true, rating: 4);
    await book('d5', 'omar', attended: true, rating: 3);
    await book('d6', 'rami', attended: true, rating: 4);
    await book('d6', 'ines', attended: true, rating: 5);
    await book('d6', 'hedi', attended: true, rating: 4);

    // Cours programmés : réservations confirmées.
    await book('s1', 'leila');
    await book('s1', 'ines');
    await book('s2', 'rami');
    await book('s2', 'salma');
    // Spinning Sunrise : complet (6/6) + liste d'attente.
    for (final u in ['ahmed', 'leila', 'omar', 'ines', 'rami', 'salma']) {
      await book('s3', u, daysBefore: 3);
    }
    await book('s4', 'omar');
    await book('s5', 'salma');
    await book('s5', 'ines');
    await book('s6', 'leila');
    await book('s7', 'rami');
    await book('s9', 'ahmed');

    for (final u in ['ahmed', 'leila', 'omar', 'ines', 'rami', 'salma']) {
      await _note(
        u,
        NotificationType.reservation,
        'Réservation confirmée',
        'Spinning Sunrise · ${_day(2, 7, 30).day}/${_day(2).month} à 07:30 · Studio Vélo',
        _now.subtract(const Duration(days: 1)),
        read: u != 'ahmed',
        route: '/courses/detail',
        refId: 'c_s3',
      );
    }
    await _note(
      'amira',
      NotificationType.course,
      'Nouveau cours affecté',
      '« Yin Yoga & respiration » (à planifier).',
      _now.subtract(const Duration(days: 5)),
      route: '/courses/detail',
      refId: 'c_p2',
    );
  }

  // ------------------------------------------------------ Historique séances

  static const Map<String, double> _baseLoad = {
    'bench': 60,
    'db_bench': 22,
    'incline_db': 20,
    'db_fly': 12,
    'cable_cross': 15,
    'latpull': 50,
    'bb_row': 50,
    'db_row': 24,
    'cable_row': 45,
    'deadlift': 100,
    'facepull': 15,
    'ohp': 40,
    'db_shoulder': 16,
    'lateral': 8,
    'reardelt': 6,
    'shrug': 24,
    'bb_curl': 30,
    'db_curl': 12,
    'hammer': 12,
    'preacher': 25,
    'pushdown': 25,
    'skull': 25,
    'oh_ext': 16,
    'squat': 80,
    'goblet': 20,
    'legpress': 120,
    'lunge': 14,
    'bulgarian': 12,
    'rdl': 60,
    'legcurl': 35,
    'legext': 40,
    'calf': 60,
    'hipthrust': 80,
    'kbswing': 16,
  };

  Future<void> _seedHistory() async {
    // (profil, facteur de charge, jours d'entraînement, semaines d'historique)
    final plans = <(String, double, Map<int, String>, int)>[
      ('ahmed', 1.0, {1: 'push', 2: 'pull', 4: 'legs', 6: 'push'}, 8),
      ('rami', 1.2, {1: 'push', 2: 'pull', 3: 'legs', 5: 'push', 6: 'pull'}, 8),
      ('leila', 0.45, {1: 'fb_a', 3: 'fb_b', 6: 'mobility'}, 8),
      ('omar', 0.55, {2: 'fb_a', 5: 'fb_b'}, 4),
      (
        'ines',
        0.5,
        {1: 'cardio_kb', 3: 'hiit_home', 5: 'core', 7: 'mobility'},
        8,
      ),
      ('salma', 0.4, {1: 'hiit_home', 3: 'core', 5: 'hiit_home'}, 8),
      ('hedi', 0.8, {2: 'upper', 4: 'lower'}, 8),
    ];

    final pending = <SessionLog>[];
    for (final (key, factor, days, weeks) in plans) {
      final userId = _ids[key]!;
      for (var d = weeks * 7; d >= 1; d--) {
        final date = _day(-d);
        var workoutKey = days[date.weekday];
        // Hedi a arrêté il y a 5 semaines (abonnement expiré).
        if (key == 'hedi' && d < 35) workoutKey = null;
        // Ahmed : série de 3 jours consécutifs pour la démo des streaks.
        if (key == 'ahmed' && d <= 3) {
          workoutKey = ['push', 'pull', 'legs'][3 - d];
        }
        if (workoutKey == null) continue;
        if (_rnd.nextDouble() < 0.12 && d > 3) continue; // séance manquée
        final weekIndex = weeks - (d ~/ 7);
        pending.add(
          _buildSession(
            userId,
            workoutKey,
            date,
            factor,
            weekIndex,
            pending.length,
          ),
        );
      }
    }
    pending.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final memberIds = [
      for (final k in ['ahmed', 'leila', 'omar', 'ines', 'rami', 'salma'])
        _ids[k]!,
    ];
    // Partage : chaque membre a choisi (ou non) de publier ses séances.
    final shareRate = <String, double>{
      _ids['ahmed']!: 0.8,
      _ids['rami']!: 0.9,
      _ids['ines']!: 0.7,
      _ids['leila']!: 0.5,
      _ids['salma']!: 0.3,
    };
    for (final s in pending) {
      final records = _b.progress.detectRecords(s.userId, s.sets, s.startedAt);
      final recent = s.startedAt.isAfter(
        _now.subtract(const Duration(days: 4)),
      );
      final shared =
          (s.userId == _ids['ahmed'] && recent) ||
          _rnd.nextDouble() < (shareRate[s.userId] ?? 0);
      final kudos = shared
          ? memberIds
                .where((id) => id != s.userId && _rnd.nextDouble() < 0.3)
                .toList()
          : <String>[];
      await _b.sessions.save(
        s.copyWith(
          prCount: records.length,
          kudos: kudos,
          shared: shared,
          sharedAt: shared ? s.endedAt : null,
        ),
      );
    }

    // Pesées hebdomadaires (tendance selon l'objectif).
    final trends = <String, (double, double)>{
      'ahmed': (79.5, 82),
      'rami': (75, 78),
      'leila': (65.5, 64),
      'omar': (90, 88),
      'ines': (57.5, 57),
      'salma': (82, 76),
      'hedi': (91, 90),
    };
    var w = 0;
    for (final e in trends.entries) {
      for (var i = 0; i <= 8; i++) {
        final t = i / 8;
        final kg =
            e.value.$1 +
            (e.value.$2 - e.value.$1) * t +
            (_rnd.nextDouble() - 0.5) * 0.6;
        await _b.weights.save(
          WeightEntry(
            id: 'wt_seed_${w++}',
            userId: _ids[e.key]!,
            date: _day(-56 + i * 7, 8),
            weightKg: double.parse(kg.toStringAsFixed(1)),
          ),
        );
      }
    }
  }

  SessionLog _buildSession(
    String userId,
    String workoutKey,
    DateTime date,
    double factor,
    int weekIndex,
    int index,
  ) {
    final workout = _b.workouts.byId('w_$workoutKey')!;
    final start = date.add(
      Duration(hours: 7 + _rnd.nextInt(12), minutes: _rnd.nextInt(4) * 15),
    );
    final sets = <SetLog>[];
    for (final item in workout.items) {
      final ex = _b.exercises.byId(item.exerciseId)!;
      final key = item.exerciseId.substring(3);
      final base = _baseLoad[key];
      for (var s = 1; s <= item.sets; s++) {
        double load = 0;
        if (base != null) {
          // Progression d'environ 1,5 % par semaine, arrondie à 2,5 kg (1 kg
          // pour les petites charges).
          final raw = base * factor * (1 + 0.015 * weekIndex);
          final step = raw >= 20 ? 2.5 : 1.0;
          load = (raw / step).round() * step;
        }
        final reps = item.isTimed
            ? 1
            : max(
                1,
                (item.reps ?? 10) - (s == item.sets ? _rnd.nextInt(2) : 0),
              );
        sets.add(
          SetLog(
            exerciseId: ex.id,
            exerciseName: ex.name,
            setIndex: s,
            reps: reps,
            loadKg: load,
            durationSec: item.isTimed ? item.durationSec : null,
          ),
        );
      }
    }
    final minutes = workout.estimatedMinutes + _rnd.nextInt(9) - 3;
    return SessionLog(
      id: 's_seed_$index',
      userId: userId,
      workoutId: workout.id,
      title: workout.name,
      startedAt: start,
      durationSec: max(10, minutes) * 60 + _rnd.nextInt(59),
      sets: sets,
      exerciseCount: workout.items.length,
    );
  }

  // --------------------------------------------------------------- Boutique

  Future<void> _seedShop() async {
    Product p(
      String key,
      String name,
      String description,
      ProductCategory cat,
      double price,
      int stock,
      List<String> images, {
      double? promo,
      bool featured = false,
    }) => Product(
      id: 'pr_$key',
      name: name,
      description: description,
      category: cat,
      price: price,
      promoPrice: promo,
      stock: stock,
      images: images.map(unsplash).toList(),
      featured: featured,
      createdAt: _day(-45),
    );

    final products = [
      p(
        'whey',
        'Whey protéine vanille 2 kg',
        'Protéine de lactosérum concentrée, 24 g de protéines par dose de 30 g. Idéale après la séance.',
        ProductCategory.supplements,
        189,
        14,
        ['photo-1693996045300-521e9d08cabc'],
        featured: true,
      ),
      p(
        'isolate',
        'Whey isolate chocolat 900 g',
        'Isolat ultra-filtré, faible en lactose et en sucres. 27 g de protéines par dose.',
        ProductCategory.supplements,
        149,
        6,
        ['photo-1704650311190-7eeb9c4f6e11'],
        promo: 129,
      ),
      p(
        'creatine',
        'Créatine monohydrate 300 g',
        'Créatine pure micronisée, 3 à 5 g par jour pour la force et la puissance.',
        ProductCategory.supplements,
        69,
        20,
        ['photo-1693996045435-af7c48b9cafb'],
      ),
      p(
        'bcaa',
        'BCAA 2:1:1 pastèque 400 g',
        'Acides aminés branchés à boire pendant l\'entraînement.',
        ProductCategory.supplements,
        79,
        0,
        ['photo-1709976142749-4a83767c4228'],
      ),
      p(
        'bar',
        'Barres protéinées (boîte de 12)',
        '20 g de protéines par barre, saveur caramel-cacahuète. Collation pratique.',
        ProductCategory.supplements,
        54,
        25,
        ['photo-1633360821154-1935fb5671e6'],
        featured: true,
      ),
      p(
        'shaker',
        'Shaker GymFlow 700 ml',
        'Shaker étanche avec grille de mélange, sans BPA.',
        ProductCategory.accessories,
        18,
        40,
        ['photo-1595348020949-87cdfbb44174'],
      ),
      p(
        'bottle',
        'Gourde isotherme 750 ml',
        'Garde l\'eau fraîche 24 h. Inox double paroi.',
        ProductCategory.accessories,
        35,
        15,
        ['photo-1649888254873-d9870ee286ee'],
      ),
      p(
        'rope',
        'Corde à sauter speed',
        'Câble acier gainé, poignées roulements à billes, longueur réglable.',
        ProductCategory.accessories,
        29,
        12,
        ['photo-1516876345887-6dd74f80787a'],
      ),
      p(
        'bands',
        'Kit élastiques de résistance (5 niveaux)',
        'Cinq bandes de 5 à 40 kg pour s\'entraîner partout.',
        ProductCategory.accessories,
        45,
        9,
        ['photo-1584827386916-b5351d3ba34b'],
        promo: 39,
        featured: true,
      ),
      p(
        'mat',
        'Tapis de yoga 6 mm',
        'Antidérapant, épaisseur confortable pour les genoux, sangle de transport.',
        ProductCategory.accessories,
        65,
        7,
        ['photo-1646239646963-b0b9be56d6b5'],
      ),
      p(
        'gloves',
        'Gants de musculation',
        'Paume renforcée et respirante pour protéger les mains.',
        ProductCategory.accessories,
        39,
        11,
        ['photo-1557127972-1c446ea89ea5'],
      ),
      p(
        'roller',
        'Rouleau de massage (foam roller)',
        'Relâchement myofascial après l\'effort, mousse haute densité.',
        ProductCategory.accessories,
        49,
        5,
        ['photo-1591741535585-9c4f52b3f13f'],
      ),
      p(
        'tshirt',
        'T-shirt technique GymFlow',
        'Tissu respirant à séchage rapide. Tailles XS à XXL.',
        ProductCategory.clothing,
        42,
        30,
        ['photo-1716951980904-fbe5c5aa2279'],
      ),
      p(
        'leggings',
        'Legging sport taille haute',
        'Maintien confortable, tissu opaque et extensible.',
        ProductCategory.clothing,
        69,
        18,
        ['photo-1600696491085-19dbbeb4f8c1'],
        featured: true,
      ),
      p(
        'towel',
        'Serviette microfibre',
        'Compacte, absorbante et à séchage rapide.',
        ProductCategory.clothing,
        22,
        3,
        ['photo-1638183130424-873c491cca1b'],
      ),
      p(
        'iso',
        'Boisson isotonique (pack de 6)',
        'Réhydratation et électrolytes pendant l\'effort. Saveur agrumes.',
        ProductCategory.drinks,
        24,
        20,
        ['photo-1506353219544-65860ffc5f41'],
      ),
    ];
    await _b.products.saveAll(products);

    Product prod(String k) => products.firstWhere((x) => x.id == 'pr_$k');
    final orders = <(String, List<(String, int)>, OrderStatus, int)>[
      ('ahmed', [('whey', 1), ('shaker', 1)], OrderStatus.delivered, 40),
      ('rami', [('creatine', 1), ('bar', 2)], OrderStatus.delivered, 25),
      ('ines', [('rope', 1), ('iso', 2)], OrderStatus.delivered, 18),
      ('salma', [('bands', 1), ('mat', 1)], OrderStatus.prepared, 4),
      ('leila', [('leggings', 1)], OrderStatus.paid, 1),
      ('rami', [('isolate', 1)], OrderStatus.paid, 0),
    ];
    var i = 0;
    for (final (user, lines, status, daysAgo) in orders) {
      i++;
      final at = _now.subtract(Duration(days: daysAgo, hours: 3 + i));
      await _b.orders.save(
        ShopOrder(
          id: 'o_seed_$i',
          number: 'GF-${at.year}-${(i).toString().padLeft(4, '0')}',
          userId: _ids[user]!,
          lines: [
            for (final (k, q) in lines)
              OrderLine(
                productId: prod(k).id,
                name: prod(k).name,
                unitPrice: prod(k).effectivePrice,
                quantity: q,
                image: prod(k).images.first,
              ),
          ],
          status: status,
          paymentMethod: 'simulated',
          paymentRef: 'SIM-SEED-${1000 + i}',
          createdAt: at,
        ),
      );
    }
    await _note(
      'salma',
      NotificationType.order,
      'Commande GF-${_now.year}-0004 prête',
      'Votre commande vous attend à l\'accueil.',
      _now.subtract(const Duration(days: 3)),
      route: '/orders',
    );
  }

  static const _couponsKey = 'shop_coupons';
  static const _couponsVersion = '1';

  /// Codes promo de démonstration (un actif, un ciblé, un expiré).
  Future<void> _upgradeCoupons() async {
    if (await _b.store.getMeta(_couponsKey) == _couponsVersion) return;
    if (_b.users.byId('u_ahmed') != null && _b.coupons.isEmpty) {
      final now = _b.now();
      DateTime day(int offset, [int h = 0, int m = 0]) =>
          DateTime(now.year, now.month, now.day + offset, h, m);
      await _b.coupons.saveAll([
        Coupon(
          id: 'cp_bienvenue',
          code: 'BIENVENUE10',
          label: 'Bienvenue à la boutique',
          type: DiscountType.percent,
          value: 10,
          minAmount: 30,
          createdAt: day(-30),
          expiresAt: day(60, 23, 59),
        ),
        Coupon(
          id: 'cp_proteine',
          code: 'PROTEINE15',
          label: 'Semaine des compléments',
          type: DiscountType.percent,
          value: 15,
          category: ProductCategory.supplements,
          maxUses: 50,
          createdAt: day(-7),
          expiresAt: day(21, 23, 59),
        ),
        Coupon(
          id: 'cp_rentree',
          code: 'RENTREE5',
          label: 'Offre de la rentrée',
          type: DiscountType.fixed,
          value: 5,
          minAmount: 40,
          maxUsesPerUser: null,
          createdAt: day(-60),
          expiresAt: day(-10, 23, 59),
        ),
      ]);
    }
    await _b.store.setMeta(_couponsKey, _couponsVersion);
  }

  static const _packsKey = 'course_packs';
  static const _packsVersion = '1';

  /// Formules et carnets de démonstration : Hedi (sans abonnement actif)
  /// a un carnet presque épuisé et une formule hebdomadaire (FEFO) ;
  /// Omar a un carnet Zen inutilisé qui expire dans 6 jours ; Ahmed a
  /// payé la clinique (cours hors abonnement) avec une séance à l'unité.
  Future<void> _upgradeCoursePacks() async {
    if (await _b.store.getMeta(_packsKey) == _packsVersion) return;
    final demo =
        _b.users.byId('u_hedi') != null &&
        _b.courses.byId('c_d6') != null &&
        _b.packOffers.isEmpty;
    if (demo) await _seedCoursePacks();
    await _b.store.setMeta(_packsKey, _packsVersion);
  }

  Future<void> _seedCoursePacks() async {
    final now = _b.now();
    DateTime day(int offset, [int h = 0, int m = 0]) =>
        DateTime(now.year, now.month, now.day + offset, h, m);
    PackOffer offer(
      String id,
      String name,
      PackKind kind,
      int quota,
      int validity,
      double price, [
      List<CourseCategory> categories = const [],
    ]) => PackOffer(
      id: id,
      name: name,
      kind: kind,
      quota: quota,
      validityDays: validity,
      price: price,
      categories: categories,
      createdAt: day(-120),
    );
    final offers = [
      offer('po_unit', 'Séance à l\'unité', PackKind.credits, 1, 30, 15),
      offer('po_5', 'Carnet 5 séances', PackKind.credits, 5, 60, 65),
      offer('po_10', 'Carnet 10 séances', PackKind.credits, 10, 120, 120),
      offer('po_zen', 'Carnet Zen 5 séances', PackKind.credits, 5, 60, 55, [
        CourseCategory.yoga,
        CourseCategory.pilates,
        CourseCategory.stretching,
      ]),
      offer(
        'po_week2',
        'Formule 2 cours par semaine',
        PackKind.weekly,
        2,
        30,
        69,
      ),
    ];
    await _b.packOffers.saveAll(offers);
    final byId = {for (final o in offers) o.id: o};

    SessionPack pack(
      String id,
      String userId,
      String offerId,
      int boughtDaysAgo,
      String ref,
    ) {
      final o = byId[offerId]!;
      final bought = day(-boughtDaysAgo, 11, 20);
      return SessionPack(
        id: id,
        userId: userId,
        offerId: o.id,
        name: o.name,
        kind: o.kind,
        quota: o.quota,
        categories: o.categories,
        purchasedAt: bought,
        expiresAt: day(-boughtDaysAgo + o.validityDays + 1),
        price: o.price + 1,
        paymentMethod: 'simulated',
        paymentRef: 'SIM-DEMO-$ref',
      );
    }

    // Hedi : 4 séances consommées sur 5 (il en reste 1), carnet acheté il
    // y a 50 jours (expire dans 11 jours, donc utilisé avant la formule
    // hebdomadaire achetée il y a 3 jours).
    var hedi5 = pack('pk_demo_hedi5', 'u_hedi', 'po_5', 50, 'HEDI5');
    final hediCourses = ['c_d1', 'c_d3', 'c_d5', 'c_d6'];
    for (var i = 0; i < hediCourses.length; i++) {
      final c = _b.courses.byId(hediCourses[i]);
      if (c == null || c.startAt == null) continue;
      var r = _b.reservations
          .where((r) => r.userId == 'u_hedi' && r.courseId == c.id)
          .firstOrNull;
      r =
          (r ??
                  Reservation(
                    id: 'r_demo_hedi_$i',
                    courseId: c.id,
                    userId: 'u_hedi',
                    status: ReservationStatus.confirmed,
                    createdAt: c.startAt!.subtract(const Duration(days: 2)),
                    attended: true,
                  ))
              .copyWith(packId: hedi5.id);
      await _b.reservations.save(r);
      hedi5 = hedi5
          .add(
            PackMovement(
              kind: PackMoveKind.reserved,
              at: r.createdAt,
              reservationId: r.id,
              courseAt: c.startAt,
            ),
          )
          .add(
            PackMovement(
              kind: PackMoveKind.consumed,
              at: c.endAt!,
              reservationId: r.id,
            ),
          );
    }
    final packs = <SessionPack>[
      hedi5,
      pack('pk_demo_hedi_week', 'u_hedi', 'po_week2', 3, 'HEDIW'),
      pack('pk_demo_omar_zen', 'u_omar', 'po_zen', 55, 'OMARZEN'),
    ];
    // Ahmed : séance à l'unité réservée pour la clinique (hors abonnement).
    final clinic = _b.courses.byId('c_s9');
    final ahmedRes = _b.reservations
        .where(
          (r) => r.userId == 'u_ahmed' && r.courseId == 'c_s9' && r.isActive,
        )
        .firstOrNull;
    if (clinic != null && ahmedRes != null) {
      final unit = pack(
        'pk_demo_ahmed_unit',
        'u_ahmed',
        'po_unit',
        1,
        'AHMED1',
      );
      packs.add(
        unit.add(
          PackMovement(
            kind: PackMoveKind.reserved,
            at: unit.purchasedAt,
            reservationId: ahmedRes.id,
            courseAt: clinic.startAt,
          ),
        ),
      );
      await _b.reservations.save(ahmedRes.copyWith(packId: unit.id));
    }
    await _b.sessionPacks.saveAll(packs);
  }

  static const _premiumKey = 'course_premium';
  static const _premiumVersion = '1';

  /// Cours premium de démonstration : 2 séances de carnet (les cours
  /// existants restent à 1 séance).
  Future<void> _upgradePremiumCourse() async {
    if (await _b.store.getMeta(_premiumKey) == _premiumVersion) return;
    if (_b.users.byId('u_sarra') != null && _b.courses.byId('c_s12') == null) {
      final now = _b.now();
      await _b.courses.save(
        Course(
          id: 'c_s12',
          title: 'Masterclass HIIT & récupération',
          description:
              'Séance premium de 75 min en petit groupe : circuit HIIT '
              'encadré puis récupération guidée (mobilité, respiration).',
          category: CourseCategory.hiit,
          level: Level.advanced,
          coachId: 'u_sarra',
          room: 'Salle Énergie',
          capacity: 10,
          durationMin: 75,
          startAt: DateTime(now.year, now.month, now.day + 6, 18),
          createdAt: now.subtract(const Duration(days: 2)),
          imageUrl: unsplash('photo-1517130038641-a774d04afb3c'),
          priceIncluded: false,
          creditCost: 2,
        ),
      );
    }
    await _b.store.setMeta(_premiumKey, _premiumVersion);
  }

  static const _courseHistoryKey = 'course_history';
  static const _courseHistoryVersion = '1';

  /// Historique de 11 semaines de cours (présences, notes, absences,
  /// annulations tardives) pour le risque d'abandon et l'affluence, avec
  /// deux abonnés de démonstration : Yassine (décrochage, risque élevé) et
  /// Mariem (nouvelle et peu active, risque moyen). Ajouté uniquement quand
  /// le jeu de démonstration est présent.
  Future<void> _upgradeCourseHistory() async {
    if (await _b.store.getMeta(_courseHistoryKey) == _courseHistoryVersion) {
      return;
    }
    if (_b.users.byId('u_amira') != null &&
        _b.users.byId('u_yassine') == null) {
      _now = _b.now();
      _today = DateTime(_now.year, _now.month, _now.day);
      await _seedCourseHistory();
    }
    await _b.store.setMeta(_courseHistoryKey, _courseHistoryVersion);
  }

  /// Créneaux hebdomadaires du planning : (jour, heure, minute, catégorie,
  /// titre, coach, salle, capacité, durée).
  static const _timetable = [
    (
      1,
      18,
      30,
      CourseCategory.yoga,
      'Yoga Vinyasa',
      'u_amira',
      'Studio Zen',
      15,
      60,
    ),
    (
      2,
      19,
      0,
      CourseCategory.hiit,
      'HIIT 45',
      'u_sarra',
      'Salle Énergie',
      20,
      45,
    ),
    (
      3,
      7,
      30,
      CourseCategory.spinning,
      'Spinning Sunrise',
      'u_sarra',
      'Studio Vélo',
      12,
      45,
    ),
    (
      3,
      18,
      30,
      CourseCategory.strength,
      'Technique squat & soulevé',
      'u_mehdi',
      'Plateau musculation',
      10,
      60,
    ),
    (
      4,
      12,
      30,
      CourseCategory.hiit,
      'HIIT Express',
      'u_sarra',
      'Salle Énergie',
      20,
      30,
    ),
    (5, 19, 0, CourseCategory.boxing, 'Boxe cardio', 'u_sarra', 'Ring', 16, 60),
    (
      6,
      10,
      0,
      CourseCategory.pilates,
      'Pilates',
      'u_amira',
      'Studio Zen',
      12,
      50,
    ),
    (
      7,
      10,
      30,
      CourseCategory.stretching,
      'Stretching',
      'u_amira',
      'Studio Zen',
      15,
      45,
    ),
  ];

  Future<void> _seedCourseHistory() async {
    final rnd = Random(47);
    AppUser member(
      String key,
      String name,
      Gender gender,
      int age,
      Goal goal,
      int createdDaysAgo,
      int subStartDaysAgo,
      SubscriptionType sub,
    ) {
      final start = _day(-subStartDaysAgo);
      return _withPrivacy(
        key,
        AppUser(
          id: 'u_$key',
          email: '$key@gymflow.tn',
          fullName: name,
          role: UserRole.member,
          gender: gender,
          age: age,
          goal: goal,
          createdAt: _day(-createdDaysAgo, 9),
          subscription: Subscription(
            type: sub,
            start: start,
            end: DateTime(start.year, start.month + sub.months, start.day),
          ),
        ),
      );
    }

    // Yassine : abonnement trimestriel qui se termine dans 5 jours.
    final yassine = member(
      'yassine',
      'Yassine Trabelsi',
      Gender.male,
      31,
      Goal.weightLoss,
      120,
      85,
      SubscriptionType.quarterly,
    );
    final mariem = member(
      'mariem',
      'Mariem Ben Salah',
      Gender.female,
      26,
      Goal.fitness,
      20,
      20,
      SubscriptionType.monthly,
    );
    for (final u in [yassine, mariem]) {
      await _b.users.save(u);
      await _b.auth.setPassword(u.id, 'Membre2026!');
    }

    // Habitudes : créneaux préférés et probabilité de venir.
    const habits = <String, (Set<int>, double)>{
      'u_leila': ({0, 6, 7}, 0.8),
      'u_ines': ({1, 2, 5}, 0.75),
      'u_ahmed': ({3, 5}, 0.75),
      'u_rami': ({1, 3}, 0.6),
      'u_salma': ({1, 4, 6}, 0.6),
      'u_omar': ({4, 7}, 0.6),
      'u_hedi': ({5}, 0.5),
    };
    final courses = <Course>[];
    final reservations = <Reservation>[];
    var n = 0;
    Reservation book(
      Course c,
      String userId, {
      bool? attended = true,
      int? rating,
      ReservationStatus status = ReservationStatus.confirmed,
      DateTime? cancelledAt,
    }) => Reservation(
      id: 'r_hist_${n++}',
      courseId: c.id,
      userId: userId,
      status: status,
      createdAt: c.startAt!.subtract(Duration(days: 2, minutes: n)),
      attended: status == ReservationStatus.confirmed ? attended : null,
      rating: rating,
      cancelledAt: cancelledAt,
    );
    final mariemSeen = <int>{};
    for (var d = 77; d >= 1; d--) {
      final date = _day(-d);
      for (var i = 0; i < _timetable.length; i++) {
        final (wd, h, m, cat, title, coach, room, cap, dur) = _timetable[i];
        if (date.weekday != wd) continue;
        final c = Course(
          id: 'c_h_${d}_$i',
          title: title,
          description: 'Cours du planning hebdomadaire.',
          category: cat,
          level: Level.intermediate,
          coachId: coach,
          room: room,
          capacity: cap,
          durationMin: dur,
          createdAt: _day(-d - 30),
          startAt: _day(-d, h, m),
        );
        courses.add(c);
        for (final e in habits.entries) {
          final (slots, p) = e.value;
          final created = _b.users.byId(e.key)?.createdAt;
          if (created == null || c.startAt!.isBefore(created)) continue;
          // Hedi ne vient plus au planning depuis 40 jours.
          if (e.key == 'u_hedi' && d < 40) continue;
          if (!slots.contains(i) || rnd.nextDouble() >= p) continue;
          final rated = rnd.nextDouble() < 0.35;
          reservations.add(
            book(c, e.key, rating: rated ? 4 + rnd.nextInt(2) : null),
          );
        }
        // Yassine : 3 cours par semaine, puis décrochage les 3 dernières
        // semaines (absences, annulations tardives, note en baisse).
        if ({0, 2, 4}.contains(i)) {
          if (d > 21) {
            if (rnd.nextDouble() < 0.85) {
              reservations.add(
                book(
                  c,
                  yassine.id,
                  rating: rnd.nextDouble() < 0.4 ? 4 + rnd.nextInt(2) : null,
                ),
              );
            }
          } else if (i == 0 && d > 14) {
            reservations.add(book(c, yassine.id, rating: 2));
          } else if (i == 0 || i == 2) {
            reservations.add(book(c, yassine.id, attended: false));
          } else {
            reservations.add(
              book(
                c,
                yassine.id,
                status: ReservationStatus.cancelled,
                cancelledAt: c.startAt!.subtract(const Duration(hours: 2)),
              ),
            );
          }
        }
        // Mariem : un premier cours, puis une absence.
        if ({0, 6}.contains(i) &&
            c.startAt!.isAfter(mariem.createdAt) &&
            mariemSeen.length < 2) {
          mariemSeen.add(d);
          reservations.add(
            book(c, mariem.id, attended: mariemSeen.length == 1),
          );
        }
      }
    }
    await _b.courses.saveAll(courses);
    await _b.reservations.saveAll(reservations);

    // Actions d'accompagnement passées (efficacité) : Hedi est revenu
    // après le message ; Yassine n'est pas revenu après l'appel ; le
    // message à Mariem est trop récent pour conclure.
    RiskAction action(
      String id,
      String member,
      String coach,
      RiskActionKind kind,
      int daysAgo,
      int score,
      String text,
    ) => RiskAction(
      id: id,
      memberId: member,
      actorId: coach,
      kind: kind,
      at: _day(-daysAgo, 11),
      score: score,
      level: ChurnRiskService.levelOf(score),
      text: text,
    );
    await _b.riskActions.saveAll([
      action(
        'ra_demo_hedi',
        'u_hedi',
        'u_sarra',
        RiskActionKind.message,
        12,
        48,
        'Bonjour Hedi, vous nous manquez ! La boxe cardio vous attend '
            'vendredi, au plaisir de vous revoir.',
      ),
      action(
        'ra_demo_yassine',
        'u_yassine',
        'u_sarra',
        RiskActionKind.call,
        15,
        52,
        'Appel : manque de temps au travail, il pense revenir le matin.',
      ),
      action(
        'ra_demo_mariem',
        'u_mariem',
        'u_amira',
        RiskActionKind.message,
        3,
        36,
        'Bonjour Mariem, bienvenue au club ! Le Pilates du samedi est idéal '
            'pour démarrer en douceur.',
      ),
    ]);
  }

  static const _checkInsKey = 'gym_checkins';
  static const _checkInsVersion = '1';

  /// Abonnés du club sans compte de connexion, et 8 semaines d'entrées
  /// scannées (Random(53)) : pics le matin, à midi et le soir, week-end
  /// plus calme. Rend la carte de chaleur et les créneaux conseillés
  /// visibles en démonstration. Les abonnés nommés de la démo n'ont pas
  /// d'entrées, pour ne pas modifier leur score de risque.
  Future<void> _upgradeCheckIns() async {
    if (await _b.store.getMeta(_checkInsKey) == _checkInsVersion) return;
    if (_b.users.byId('u_amira') != null && _b.checkIns.isEmpty) {
      _now = _b.now();
      _today = DateTime(_now.year, _now.month, _now.day);
      await _seedCheckIns();
    }
    await _b.store.setMeta(_checkInsKey, _checkInsVersion);
  }

  static const _clubFirst = [
    'Aymen',
    'Sami',
    'Nadia',
    'Hela',
    'Karim',
    'Mouna',
    'Bilel',
    'Sonia',
    'Anis',
    'Rim',
    'Fares',
    'Emna',
    'Zied',
    'Asma',
    'Wassim',
    'Amal',
    'Hamza',
    'Olfa',
    'Skander',
    'Dorra',
    'Mehdi',
    'Ines',
    'Slim',
    'Yosra',
    'Tarek',
  ];
  static const _clubLast = [
    'Mansour',
    'Jaziri',
    'Bouaziz',
    'Hammami',
    'Chaabane',
    'Gharbi',
    'Sfaxi',
    'Kefi',
    'Toumi',
    'Abidi',
  ];

  Future<void> _seedCheckIns() async {
    final rnd = Random(53);
    // Heures de prédilection : matin, midi, soir, fin de soirée.
    const bands = [7, 12, 18, 19, 18, 20, 9];
    final members = <AppUser>[];
    final habits = <String, (int, double)>{};
    for (var i = 0; i < 50; i++) {
      final first = _clubFirst[i % _clubFirst.length];
      final last =
          _clubLast[(i * 7 + i ~/ _clubFirst.length) % _clubLast.length];
      final n = (i + 1).toString().padLeft(2, '0');
      final u = AppUser(
        id: 'u_club_$n',
        email: 'club$n@gymflow.tn',
        fullName: '$first $last',
        role: UserRole.member,
        gender: i.isEven ? Gender.male : Gender.female,
        goal: Goal.values[i % Goal.values.length],
        createdAt: _day(-150 - i, 10),
        subscription: Subscription(
          type: SubscriptionType.yearly,
          start: _day(-150 - i),
          end: _day(215 - i),
        ),
      );
      members.add(u);
      habits[u.id] = (
        bands[rnd.nextInt(bands.length)],
        2 + rnd.nextDouble() * 2,
      );
    }
    await _b.users.saveAll(members);

    final checkIns = <CheckIn>[];
    var k = 0;
    for (var d = 56; d >= 0; d--) {
      final day = _day(-d);
      final weekend = day.weekday >= 6;
      // Lundi et mardi : début de semaine plus fréquenté.
      final boost = day.weekday <= 2 ? 1.3 : (weekend ? 0.6 : 1.0);
      for (final u in members) {
        final (band, perWeek) = habits[u.id]!;
        if (rnd.nextDouble() >= perWeek / 7 * boost) continue;
        final hour = weekend
            ? 9 + rnd.nextInt(3)
            : band + rnd.nextInt(2) - (band > 7 ? rnd.nextInt(2) : 0);
        final at = DateTime(
          day.year,
          day.month,
          day.day,
          hour,
          rnd.nextInt(60),
        );
        if (!at.isBefore(_now)) continue;
        final staysMin = 50 + rnd.nextInt(51);
        final exit = at.add(Duration(minutes: staysMin));
        checkIns.add(
          CheckIn(
            id: 'ci_demo_${k++}',
            userId: u.id,
            at: at,
            byId: 'u_admin',
            // Sortie scannée 2 fois sur 3 ; sinon sortie automatique.
            exitAt: rnd.nextDouble() < 0.66 && exit.isBefore(_now)
                ? exit
                : null,
          ),
        );
      }
    }
    await _b.checkIns.saveAll(checkIns);
    // Petit plateau de démonstration : 20 personnes en même temps.
    await _b.gymSettings.save(_b.packs.settings.copyWith(capacity: 20));
  }

  static const _ramadanKey = 'ramadan_2026';
  static const _ramadanVersion = '1';

  /// Ramadan 1447 (2026) confirmé : Aladhan proposait le 18/02, le Mufti
  /// de la République a annoncé le jeudi 19/02 (croissant non observé le
  /// 17/02) et l'Aïd le 20/03. Entrées de démonstration pendant cette
  /// période (Random(61)) : peu de monde en journée, pic après la rupture
  /// du jeûne. Elles forment le profil d'affluence du Ramadan.
  Future<void> _upgradeRamadan() async {
    if (await _b.store.getMeta(_ramadanKey) == _ramadanVersion) return;
    final start = DateTime(2026, 2, 19);
    final end = DateTime(2026, 3, 19);
    final demo = _b.users.byId('u_club_01') != null;
    if (demo &&
        _b.now().isAfter(end) &&
        _b.packs.settings.ramadanPeriods.isEmpty) {
      await _b.gymSettings.save(
        _b.packs.settings.copyWith(
          ramadanPeriods: [
            RamadanPeriod(
              hijriYear: 1447,
              start: start,
              end: end,
              confirmed: true,
              source:
                  'Aladhan proposait le 18/02 ; annonce officielle du Mufti : '
                  'jeudi 19/02',
            ),
          ],
        ),
      );
      final rnd = Random(61);
      final members = _b.users.where((u) => u.id.startsWith('u_club_'));
      final checkIns = <CheckIn>[];
      var k = 0;
      for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
        final maghrib = d.add(Duration(minutes: AladhanApi.estimateMinutes(d)));
        for (final u in members) {
          if (rnd.nextDouble() >= 0.42) continue;
          final roll = rnd.nextDouble();
          final DateTime at;
          if (roll < 0.2) {
            // Journée, avant le jeûne de l'après-midi.
            at = DateTime(
              d.year,
              d.month,
              d.day,
              10 + rnd.nextInt(4),
              rnd.nextInt(60),
            );
          } else if (roll < 0.85) {
            // Après la rupture du jeûne.
            at = maghrib.add(Duration(minutes: 50 + rnd.nextInt(150)));
          } else {
            at = DateTime(d.year, d.month, d.day, 22, rnd.nextInt(60));
          }
          checkIns.add(
            CheckIn(
              id: 'ci_ram_${k++}',
              userId: u.id,
              at: at,
              byId: 'u_admin',
              exitAt: at.add(Duration(minutes: 50 + rnd.nextInt(40))),
            ),
          );
        }
      }
      await _b.checkIns.saveAll(checkIns);
    }
    await _b.store.setMeta(_ramadanKey, _ramadanVersion);
  }

  static const _historyKey = 'shop_history';
  static const _historyVersion = '1';

  /// Historique de commandes des 90 derniers jours, pour les
  /// recommandations et la prévision des ruptures. Ajouté uniquement quand
  /// le jeu de démonstration est présent (jamais sur une base réelle).
  Future<void> _upgradeOrderHistory() async {
    if (await _b.store.getMeta(_historyKey) == _historyVersion) return;
    final demo =
        _b.users.byId('u_ahmed') != null && _b.products.byId('pr_whey') != null;
    if (demo && _b.orders.byId('o_hist_1') == null) {
      _now = _b.now();
      _today = DateTime(_now.year, _now.month, _now.day);
      await _seedOrderHistory();
    }
    await _b.store.setMeta(_historyKey, _historyVersion);
  }

  /// Génération déterministe (graine fixe) : mêmes commandes à chaque
  /// installation, donc des résultats et des tests stables.
  Future<void> _seedOrderHistory() async {
    final rnd = Random(90);
    if (_b.products.byId('pr_belt') == null) {
      await _b.products.save(
        Product(
          id: 'pr_belt',
          name: 'Ceinture de musculation',
          description:
              'Ceinture de 10 cm pour le maintien lombaire sur les charges '
              'lourdes (squat, soulevé de terre).',
          category: ProductCategory.accessories,
          price: 59,
          stock: 8,
          createdAt: _day(-120),
        ),
      );
    }
    // Premier article d'une commande : (produit, poids, quantité max).
    // Rouleau de massage et serviette ne sont jamais vendus (classe C).
    const anchors = <(String, int, int)>[
      ('whey', 14, 1),
      ('isolate', 8, 2),
      ('iso', 12, 3),
      ('bar', 9, 2),
      ('creatine', 8, 1),
      ('gloves', 6, 1),
      ('tshirt', 5, 2),
      ('rope', 4, 1),
      ('mat', 4, 1),
      ('bands', 3, 1),
      ('leggings', 3, 1),
      ('bcaa', 3, 1),
      ('shaker', 3, 1),
      ('bottle', 3, 1),
      ('belt', 3, 1),
    ];
    // Achats associés au premier article : (produit, probabilité).
    const companions = <String, List<(String, double)>>{
      'whey': [('shaker', 0.45), ('creatine', 0.2)],
      'creatine': [('whey', 0.5)],
      'isolate': [('shaker', 0.3), ('bar', 0.2)],
      'iso': [('bottle', 0.4)],
      'gloves': [('belt', 0.45)],
      'belt': [('gloves', 0.5)],
      'mat': [('bands', 0.45)],
      'rope': [('bottle', 0.3)],
      'tshirt': [('leggings', 0.3)],
    };
    // Acheteurs selon le rayon, cohérents avec leur objectif.
    const buyers = <ProductCategory, List<String>>{
      ProductCategory.supplements: ['ahmed', 'rami', 'rami', 'omar'],
      ProductCategory.accessories: ['salma', 'leila', 'omar', 'ahmed'],
      ProductCategory.clothing: ['leila', 'salma', 'ines'],
      ProductCategory.drinks: ['ines', 'ines', 'salma', 'rami'],
    };
    String pick(int daysAgo) {
      // L'isolat se vend de plus en plus (proche de la rupture) ; les BCAA,
      // en rupture, ne se vendent plus depuis 25 jours.
      int weight((String, int, int) a) => switch (a.$1) {
        'isolate' when daysAgo <= 21 => a.$2 * 5,
        'bcaa' when daysAgo <= 25 => 0,
        _ => a.$2,
      };
      var r = rnd.nextInt(anchors.fold(0, (s, a) => s + weight(a)));
      for (final a in anchors) {
        r -= weight(a);
        if (r < 0) return a.$1;
      }
      return anchors.first.$1;
    }

    final numbers = <int, int>{};
    final orders = <ShopOrder>[];
    for (var i = 1; i <= 110; i++) {
      final daysAgo = 1 + rnd.nextInt(90);
      final first = pick(daysAgo);
      final maxQty = anchors.firstWhere((a) => a.$1 == first).$3;
      final quantities = <String, int>{first: 1 + rnd.nextInt(maxQty)};
      for (final (k, prob) in companions[first] ?? const <(String, double)>[]) {
        if (rnd.nextDouble() < prob) quantities.putIfAbsent(k, () => 1);
      }
      // Un article sans lien, de temps en temps.
      if (rnd.nextDouble() < 0.1) {
        quantities.putIfAbsent(pick(daysAgo), () => 1);
      }
      final at = _day(-daysAgo, 8 + rnd.nextInt(13), rnd.nextInt(60));
      final products = [
        for (final k in quantities.keys) _b.products.byId('pr_$k')!,
      ];
      final who = buyers[products.first.category]!;
      final year = at.year;
      numbers[year] =
          (numbers[year] ??
              _b.orders.where((o) => o.createdAt.year == year).length) +
          1;
      orders.add(
        ShopOrder(
          id: 'o_hist_$i',
          number: 'GF-$year-${numbers[year].toString().padLeft(4, '0')}',
          userId: 'u_${who[rnd.nextInt(who.length)]}',
          lines: [
            for (final p in products)
              OrderLine(
                productId: p.id,
                name: p.name,
                unitPrice: p.effectivePrice,
                quantity: quantities[p.id.substring(3)]!,
                image: p.images.isEmpty ? null : p.images.first,
              ),
          ],
          status: daysAgo <= 1
              ? OrderStatus.paid
              : (daysAgo <= 4 ? OrderStatus.prepared : OrderStatus.delivered),
          paymentMethod: 'simulated',
          paymentRef: 'SIM-HIST-${1000 + i}',
          createdAt: at,
        ),
      );
    }
    await _b.orders.saveAll(orders);
  }

  Future<void> _seedAnnouncements() async {
    await _b.announcementsRepo.saveAll([
      Announcement(
        id: 'an_1',
        title: 'Ouverture dès 6 h en semaine',
        body:
            'À partir de lundi, la salle ouvre à 6 h du lundi au vendredi pour les lève-tôt !',
        authorId: _ids['admin']!,
        createdAt: _now.subtract(const Duration(days: 2)),
        imageUrl: unsplash('photo-1593079831268-3381b0db4a77'),
        pinned: true,
      ),
      Announcement(
        id: 'an_2',
        title: '-15 % sur les compléments',
        body:
            'Tout le mois, profitez de prix réduits sur une sélection de compléments à la boutique.',
        authorId: _ids['admin']!,
        createdAt: _now.subtract(const Duration(days: 4)),
        imageUrl: unsplash('photo-1693996045300-521e9d08cabc'),
      ),
      Announcement(
        id: 'an_3',
        title: 'Défi du mois : 12 séances',
        body:
            'Réalisez 12 séances ce mois-ci et gagnez un t-shirt GymFlow. Suivez votre compteur dans votre profil.',
        authorId: _ids['admin']!,
        createdAt: _now.subtract(const Duration(days: 6)),
        imageUrl: unsplash('photo-1633394782240-f81aba3f850d'),
      ),
    ]);
  }
}
