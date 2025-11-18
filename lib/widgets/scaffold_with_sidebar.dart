import 'package:flutter/material.dart';
import 'package:thesis_web/widgets/app_nav.dart';

class ScaffoldWithSidebar extends StatelessWidget {
  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? floatingActionButton;

  const ScaffoldWithSidebar({super.key, this.appBar, required this.body, this.floatingActionButton});

  @override
  Widget build(BuildContext context) {
    final bool isWide = MediaQuery.of(context).size.width >= 1000;
    final nav = appNavList(context, closeDrawer: !isWide);
    if (!isWide) {
      return Scaffold(
        appBar: appBar,
        drawer: Drawer(child: nav),
        body: body,
        floatingActionButton: floatingActionButton,
      );
    }
    return Scaffold(
      appBar: appBar,
      body: Row(
        children: [
          Container(width: 280, color: Colors.white, child: nav),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ],
      ),
      floatingActionButton: floatingActionButton,
    );
  }
}


