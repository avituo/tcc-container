CREATE DATABASE IF NOT EXISTS tcc_products_experiment CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS tcc_orders_experiment CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON tcc_products_experiment.* TO 'tcc'@'%';
GRANT ALL PRIVILEGES ON tcc_orders_experiment.* TO 'tcc'@'%';

